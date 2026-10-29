import Foundation
import GRDB
import Testing
@testable import PinpageCore

private let paragraphs = [
    "교착 상태(데드락)는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생긴다.",
    "경쟁 상태는 여러 스레드가 공유 데이터에 동시에 접근할 때 실행 순서에 따라 결과가 달라지는 문제다. 뮤텍스나 세마포어로 임계 구역을 보호해 막는다.",
    "너비 우선 탐색(BFS)은 시작 노드에서 가까운 노드부터 차례로 방문한다. 큐를 사용하며, 가중치가 없는 그래프에서 최단 경로를 찾을 때 쓴다.",
]

private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// 문단 하나가 청크 하나인 색인된 세트.
private func indexedSet() async throws -> (Library, String) {
    let library = Library(database: try AppDatabase.inMemory(),
                          filesRoot: FileManager.default.temporaryDirectory.appending(path: "pinpage-prob-\(UUID().uuidString)"))
    let set = try library.createSet(name: "CS")
    let pdf = try TestPDF.make(pages: [paragraphs])
    let document = try library.importPDF(from: pdf, into: set.id)
    try await DocumentIndexer(library: library).index(
        documentId: document.id,
        options: IndexingOptions(chunkSize: 800, chunkOverlap: 100, minChunkLength: 0, ocrLanguages: [], prompts: nil),
        embedder: nil)
    return (library, set.id)
}

private func stubClient() throws -> OpenAIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChatServerStub.self]
    return OpenAIClient(endpoint: try APIEndpoint(baseURL: "gpu-server:8000"), timeoutSeconds: 10,
                        retryPolicy: RetryPolicy(maxRetries: 0), session: URLSession(configuration: configuration))
}

private func request(temperature: Double = 0.7) -> StructuredRequest {
    StructuredRequest(model: "qwen", temperature: temperature, maxTokens: 512, enforceJSONSchema: true,
                      extraBody: ["chat_template_kwargs": ["enable_thinking": false]])
}

private func chunks(_ library: Library) throws -> [Chunk] {
    try library.database.writer.read { db in try Chunk.order(Column("ordinal")).fetchAll(db) }
}

extension ChatStubbed {
    @Suite("연습 문제 만들기")
    struct ProblemGeneratorTests {
        private func generator(_ library: Library, random: @escaping @Sendable (Int) -> Int = { _ in 0 }) throws -> ProblemGenerator {
            ProblemGenerator(database: library.database, client: try stubClient(), templates: try realTemplates(),
                             request: request(), random: random)
        }

        private func mcResponse(quote: String) -> ChatServerStub.Reply {
            .content(json([
                "status": "ok", "question": "교착 상태가 생기는 조건이 아닌 것은?",
                "choices": ["상호 배제", "점유 대기", "선점 가능", "순환 대기"], "answer_index": 2,
                "accepted_answers": [], "model_answer": "",
                "key_points": [["point": "네 조건은 상호 배제, 점유 대기, 비선점, 순환 대기", "source": 1, "quote": quote]],
            ]))
        }

        @Test("근거가 확인되고 검증 풀이가 정답과 같은 객관식 문제를 만들어 저장한다")
        func generatesProblem() async throws {
            let (library, setId) = try await indexedSet()
            ChatServerStub.queue([mcResponse(quote: "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생긴다."),
                                  .content(json(["answerable": true, "answer": 3]))])
            let output = try await generator(library).generate(setId: setId, types: [.multipleChoice], difficulty: 3)
            let problem = output.problem
            #expect(output.failures.isEmpty)
            #expect(problem.type == .multipleChoice)
            #expect(problem.difficulty == 3)
            #expect(problem.answerIndex == 2)
            #expect(problem.choices.count == 4)
            #expect(problem.modelAnswer == "선점 가능")  // 객관식은 정답 보기를 모범 답안으로
            #expect(problem.keyPoints.count == 1)
            #expect(problem.status == .generated)
            let all = try chunks(library)
            #expect(problem.sourceChunkIds == [all[0].id!, all[1].id!])  // 고른 청크 + 다음 청크
            #expect(problem.promptText.contains("3) 선점 가능"))
            let stored = try await library.database.writer.read { db in try PracticeProblem.fetchOne(db, key: problem.id) }
            // DB는 날짜를 밀리초까지 저장하므로 날짜를 뺀 내용을 비교한다.
            #expect(stored?.question == problem.question)
            #expect(stored?.choices == problem.choices && stored?.answerIndex == problem.answerIndex)
            #expect(stored?.keyPoints == problem.keyPoints && stored?.sourceChunkIds == problem.sourceChunkIds)

            let body = try #require(ChatServerStub.requests.first)
            #expect(body["temperature"] as? Double == 0.7)
            let user = (body["messages"] as? [[String: String]])?[1]["content"] ?? ""
            #expect(user.contains("문제 유형: multiple_choice"))
            #expect(user.contains("난이도: 3"))
            #expect(user.contains("(없음)"))
            #expect(!user.contains("{{"))

            // 두 번째 요청은 검증 풀이: temperature 0, 보기는 1부터 번호
            let check = try #require(ChatServerStub.requests.last)
            #expect(ChatServerStub.requests.count == 2)
            #expect(check["temperature"] as? Double == 0)
            let checkUser = (check["messages"] as? [[String: String]])?[1]["content"] ?? ""
            #expect(checkUser.contains("3) 선점 가능"))
            #expect(!checkUser.contains("answer_index") && !checkUser.contains("상호 배제, 점유 대기, 비선점, 순환 대기\n"))  // 정답 번호와 요점을 알려주지 않는다
            #expect(!checkUser.contains("네 조건은"))
        }

        @Test("검증 풀이가 정답과 다르거나 풀 수 없으면 버린다")
        func rejectsWrongKey() async throws {
            let (library, setId) = try await indexedSet()
            // 재시도마다 다른 청크를 고르므로(첫 청크 → 둘째 → 셋째) 인용도 그 청크의 문장으로 준다.
            ChatServerStub.queue([
                mcResponse(quote: "상호 배제, 점유 대기, 비선점, 순환 대기 네 조건이 모두 성립할 때 생긴다."),
                .content(json(["answerable": true, "answer": 1])),
                mcResponse(quote: "뮤텍스나 세마포어로 임계 구역을 보호해 막는다."),
                .content(json(["answerable": false, "answer": -1])),
                mcResponse(quote: "큐를 사용하며"),
                .content(json(["answerable": true, "answer": 3])),
            ])
            let output = try await generator(library).generate(setId: setId, types: [.multipleChoice], difficulty: 2)
            #expect(output.failures.map(\.reason) == ["검증 풀이(1번)와 정답(3번) 불일치", "검증 풀이에서 풀 수 없다고 판단"])
            #expect(output.problem.answerIndex == 2)
        }

        @Test("근거 인용이 자료에 없으면 버리고 다른 부분에서 다시 만든다")
        func retriesOnUnverifiedQuote() async throws {
            let (library, setId) = try await indexedSet()
            ChatServerStub.queue([
                .content(json([
                    "status": "ok", "question": "교착 상태는 어떻게 해결되나?", "choices": [], "answer_index": -1,
                    "accepted_answers": [], "model_answer": "운영체제가 자동으로 해결한다.",
                    "key_points": [["point": "자동 해결", "source": 1, "quote": "교착 상태는 운영체제가 자동으로 해결한다."]],
                ])),
                .content(json([
                    "status": "ok", "question": "경쟁 상태를 막는 방법은?", "choices": [], "answer_index": -1,
                    "accepted_answers": [], "model_answer": "뮤텍스나 세마포어로 임계 구역을 보호한다.",
                    "key_points": [["point": "임계 구역 보호", "source": 1, "quote": "뮤텍스나 세마포어로 임계 구역을 보호해 막는다."]],
                ])),
            ])
            let output = try await generator(library).generate(setId: setId, types: [.essay], difficulty: 2)
            #expect(output.failures.map(\.reason) == ["근거가 확인되는 채점 요점 없음"])
            #expect(output.problem.type == .essay)
            #expect(output.problem.question == "경쟁 상태를 막는 방법은?")
            #expect(output.problem.sourceChunkIds.first != output.failures[0].chunkId)
        }

        @Test("세 번 모두 실패하면 오류와 실패 사유를 알려준다")
        func givesUp() async throws {
            let (library, setId) = try await indexedSet()
            ChatServerStub.queue([
                .content(json(["status": "insufficient", "question": "", "choices": [], "answer_index": -1,
                               "accepted_answers": [], "model_answer": "", "key_points": []])),
                .content(json(["status": "ok", "question": "q", "choices": ["a", "b"], "answer_index": 0,
                               "accepted_answers": [], "model_answer": "", "key_points": []])),
                .content("형식 없는 답"),
            ])
            do {
                _ = try await generator(library).generate(setId: setId, types: [.multipleChoice], difficulty: 2)
                Issue.record("오류가 나야 함")
            } catch ProblemGenerationError.noValidProblem(let failures) {
                #expect(failures.map(\.reason) == ["자료가 부족하다고 판단", "객관식 보기는 서로 다른 3~6개여야 함", "형식 오류"])
            }
        }

        @Test("자료가 없으면 바로 알려준다")
        func noMaterials() async throws {
            let library = Library(database: try AppDatabase.inMemory(), filesRoot: FileManager.default.temporaryDirectory)
            let set = try library.createSet(name: "빈 세트")
            ChatServerStub.queue([])
            await #expect(throws: ProblemGenerationError.self) {
                try await generator(library).generate(setId: set.id, types: [.essay], difficulty: 2)
            }
            #expect(ChatServerStub.requests.isEmpty)
        }

        @Test("출제 위치: 안 낸 부분 먼저, 빠진 요점이 나온 부분은 다시 묻는다")
        func targetPriority() async throws {
            let (library, setId) = try await indexedSet()
            let all = try chunks(library)
            let generator = try generator(library)
            // 처음에는 모두 안 낸 부분 → 무작위(여기서는 첫 번째)
            #expect(try generator.pickTarget(setId: setId, excluding: [])?.chunk.id == all[0].id)

            // 첫 청크에서 한 문제 냈으면 다음은 안 낸 청크
            var problem = PracticeProblem(
                id: "p1", setId: setId, type: .essay, difficulty: 2, question: "교착 상태란?", choices: [], answerIndex: nil,
                acceptedAnswers: [], modelAnswer: "m",
                keyPoints: [KeyPoint(text: "네 조건", chunkId: all[0].id!, quote: "네 조건")],
                sourceChunkIds: [all[0].id!], status: .shown, createdAt: Date(timeIntervalSinceNow: -60), shownAt: nil,
                model: "qwen", templateFingerprint: "f", rawResponse: "", latencyMs: 0)
            let first = problem
            try await library.database.writer.write { db in try first.insert(db) }
            let next = try generator.pickTarget(setId: setId, excluding: [])
            #expect(next?.chunk.id == all[1].id)

            // 첫 청크 요점을 틀렸으면 그 부분을 다시 묻고, 앞서 낸 문제를 피하라고 알려준다
            let attempt = ProblemAttempt(id: nil, problemId: "p1", answer: "모름", verdict: .incorrect, score: 0, feedback: "",
                                         missedKeyPoints: [0], gradedBy: "ai", rawResponse: nil, latencyMs: 0, createdAt: Date())
            try await library.database.writer.write { db in
                var inserted = attempt
                try inserted.insert(db)
            }
            let weak = try generator.pickTarget(setId: setId, excluding: [])
            #expect(weak?.chunk.id == all[0].id)
            #expect(weak?.previousQuestions == ["교착 상태란?"])

            // 그 부분에서 새 문제를 냈으면 더 이상 약한 부분이 아니다
            problem.id = "p2"
            problem.createdAt = Date(timeIntervalSinceNow: 1)
            let second = problem
            try await library.database.writer.write { db in try second.insert(db) }
            #expect(try generator.pickTarget(setId: setId, excluding: [])?.chunk.id == all[1].id)

            // 계속 틀려도 한 부분에서는 3번까지만 낸다
            problem.id = "p3"
            problem.createdAt = Date(timeIntervalSinceNow: 2)
            let third = problem
            let miss = ProblemAttempt(id: nil, problemId: "p3", answer: "모름", verdict: .incorrect, score: 0, feedback: "",
                                      missedKeyPoints: [0], gradedBy: "ai", rawResponse: nil, latencyMs: 0,
                                      createdAt: Date(timeIntervalSinceNow: 3))
            try await library.database.writer.write { db in
                try third.insert(db)
                var inserted = miss
                try inserted.insert(db)
            }
            #expect(try generator.pickTarget(setId: setId, excluding: [])?.chunk.id != all[0].id)
        }
    }

    @Suite("답안 채점")
    struct ProblemGraderTests {
        private func setup(_ type: ProblemType) async throws -> (Library, ProblemGrader, PracticeProblem) {
            let (library, setId) = try await indexedSet()
            let all = try chunks(library)
            let problem = PracticeProblem(
                id: UUID().uuidString, setId: setId, type: type, difficulty: 2,
                question: type == .multipleChoice ? "교착 상태 조건이 아닌 것은?" : "가중치 없는 그래프의 최단 경로 탐색은?",
                choices: type == .multipleChoice ? ["상호 배제", "점유 대기", "선점 가능", "순환 대기"] : [],
                answerIndex: type == .multipleChoice ? 2 : nil,
                acceptedAnswers: type == .shortAnswer ? ["BFS", "너비 우선 탐색"] : [],
                modelAnswer: "너비 우선 탐색(BFS)을 쓰고 큐가 필요하다.",
                keyPoints: [KeyPoint(text: "BFS", chunkId: all[2].id!, quote: "너비 우선 탐색(BFS)"),
                            KeyPoint(text: "큐 사용", chunkId: all[2].id!, quote: "큐를 사용하며")],
                sourceChunkIds: [all[2].id!], status: .shown, createdAt: Date(), shownAt: Date(),
                model: "qwen", templateFingerprint: "f", rawResponse: "", latencyMs: 0)
            try await library.database.writer.write { db in try problem.insert(db) }
            let grader = ProblemGrader(database: library.database, client: try stubClient(), templates: try realTemplates(),
                                       request: request(temperature: 0))
            return (library, grader, problem)
        }

        @Test("객관식은 코드로 채점하고, 맞히면 문제를 푼 것으로 표시한다")
        func multipleChoice() async throws {
            let (library, grader, problem) = try await setup(.multipleChoice)
            ChatServerStub.queue([])
            let wrong = try await grader.grade(problem, answer: "0")
            #expect(wrong.verdict == .incorrect && wrong.score == 0 && wrong.gradedBy == "code")
            #expect(wrong.missedKeyPoints == [0, 1])
            let right = try await grader.grade(problem, answer: "2")
            #expect(right.verdict == .correct && right.score == 1 && right.missedKeyPoints.isEmpty)
            #expect(ChatServerStub.requests.isEmpty)
            let stored = try await library.database.writer.read { db in try PracticeProblem.fetchOne(db, key: problem.id) }
            #expect(stored?.status == .solved)
            let count = try await library.database.writer.read { db in try ProblemAttempt.fetchCount(db) }
            #expect(count == 2)
        }

        @Test("단답형은 정답 목록과 같으면 AI 없이 정답 (공백·대소문자·문장부호 무시)")
        func shortAnswerExact() async throws {
            let (_, grader, problem) = try await setup(.shortAnswer)
            ChatServerStub.queue([])
            #expect(try await grader.grade(problem, answer: " b.f.s ").verdict == .correct)
            #expect(try await grader.grade(problem, answer: "너비우선탐색").verdict == .correct)
            #expect(ChatServerStub.requests.isEmpty)
        }

        @Test("단답형이 목록과 다르면 AI가 채점하고, 빠진 요점 번호를 0부터로 바꾼다")
        func shortAnswerAI() async throws {
            let (_, grader, problem) = try await setup(.shortAnswer)
            ChatServerStub.queue([.content(json(["verdict": "partial", "score": 1.7, "feedback": "자료구조도 생각해 보세요.",
                                                 "missed_key_points": [2, 9]]))])
            let attempt = try await grader.grade(problem, answer: "가까운 곳부터 넓게 찾는 탐색")
            #expect(attempt.verdict == .partial)
            #expect(attempt.score == 1)  // 0~1로 자른다
            #expect(attempt.missedKeyPoints == [1])  // 9번은 범위 밖이라 버림
            #expect(attempt.gradedBy == "ai")
            #expect(attempt.feedback == "자료구조도 생각해 보세요.")
            let user = (ChatServerStub.requests.first?["messages"] as? [[String: String]])?[1]["content"] ?? ""
            #expect(user.contains("1. BFS (근거: 너비 우선 탐색(BFS))"))
            #expect(user.contains("학습자 답안: 가까운 곳부터 넓게 찾는 탐색"))
            #expect(ChatServerStub.requests.first?["temperature"] as? Double == 0)
        }

        @Test("서술형을 틀렸는데 빠진 요점을 안 짚으면 모든 요점을 다시 보게 한다")
        func essayIncorrect() async throws {
            let (_, grader, problem) = try await setup(.essay)
            ChatServerStub.queue([.content(json(["verdict": "incorrect", "score": 0, "feedback": "다시 읽어 보세요.",
                                                 "missed_key_points": []]))])
            let attempt = try await grader.grade(problem, answer: "깊이 우선 탐색을 쓴다")
            #expect(attempt.missedKeyPoints == [0, 1])
        }

        @Test("빈 답안은 AI 없이 틀림")
        func emptyAnswer() async throws {
            let (_, grader, problem) = try await setup(.essay)
            ChatServerStub.queue([])
            let attempt = try await grader.grade(problem, answer: "   ")
            #expect(attempt.verdict == .incorrect && attempt.gradedBy == "code")
            #expect(ChatServerStub.requests.isEmpty)
        }
    }
}

@Suite("이벤트 로그")
struct EventLogTests {
    @Test("순번, UTC 밀리초 시각, 키 정렬된 내용, 세션 정보를 기록한다")
    func records() throws {
        let database = try AppDatabase.inMemory()
        let fixed = Date(timeIntervalSince1970: 1_793_200_000.125)  // 2026-10-28 15:06:40.125 UTC
        let logger = EventLogger(database: database, appVersion: "0.1.0", now: { fixed })
        let first = try logger.record(.appLaunch, AppStatePayload(reason: "launch"))
        logger.context = .init(sessionId: "s1", participantId: "P07")
        let second = try logger.record(.questionAsked, RequestPayload(requestId: "r1", setId: "set", problemId: nil,
                                                                       question: "데드락이란?", hintLevel: nil))
        #expect(second == first + 1)

        let events = try logger.all()
        #expect(events.map(\.type) == ["app_launch", "question_asked"])
        #expect(events[0].timestamp == "2026-10-28T15:06:40.125Z")
        #expect(events[0].sessionId == nil)
        #expect(events[1].sessionId == "s1" && events[1].participantId == "P07")
        #expect(events[1].appVersion == "0.1.0")
        #expect(events[1].payload == #"{"question":"데드락이란?","requestId":"r1","setId":"set"}"#)
        #expect(try logger.all(sessionId: "s1").count == 1)
        #expect(try logger.recent(limit: 1).first?.type == "question_asked")
    }

    @Test("파일 DB를 닫았다 열어도 기록이 남고 순번이 이어진다")
    func persists() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-log-\(UUID().uuidString)/pinpage.sqlite")
        do {
            let logger = EventLogger(database: try AppDatabase.open(at: url), appVersion: "1")
            try logger.record(.appLaunch, EmptyPayload())
            try logger.record(.appPause, AppStatePayload(reason: "inactive"))
        }
        let reopened = EventLogger(database: try AppDatabase.open(at: url), appVersion: "1")
        let seq = try reopened.record(.appResume, AppStatePayload(reason: "active"))
        #expect(seq == 3)
        #expect(try reopened.all().map(\.type) == ["app_launch", "app_pause", "app_resume"])
    }

    @Test("LLM 요청의 시도마다 llm_call 이벤트를 남긴다")
    func llmCalls() async throws {
        let logger = EventLogger(database: try AppDatabase.inMemory(), appVersion: "1")
        let recorder = EventLLMCallRecorder(logger: logger)
        await recorder.record(LLMCallRecord(operation: .chat, baseURL: "http://gpu-server:8000/v1", model: "qwen", attempt: 1,
                                            outcome: .retry, latencyMs: 120, statusCode: 503, errorCode: "server_error",
                                            startedAt: Date(timeIntervalSince1970: 0)))
        let event = try #require(try logger.all().first)
        #expect(event.type == "llm_call")
        let payload = try JSONSerialization.jsonObject(with: Data(event.payload.utf8)) as? [String: Any]
        #expect(payload?["outcome"] as? String == "retry")
        #expect(payload?["latencyMs"] as? Int == 120)
        #expect(payload?["statusCode"] as? Int == 503)
        #expect(payload?["startedAt"] as? String == "1970-01-01T00:00:00.000Z")
    }

    @Test("답변 이벤트의 필드 구성이 고정돼 있다 (내보내기 열과 일치)")
    func groundedPayloadKeys() throws {
        let payload = GroundedPayload(requestId: "r", setId: "s", problemId: nil, kind: "answer", hintLevel: nil,
                                      question: "q", problem: nil, error: "실패", model: "qwen", templateFingerprint: "f",
                                      startedAt: Date(timeIntervalSince1970: 0))
        let encoded = try EventLogger.encode(payload)
        let keys = Set((try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])?.keys.map { $0 } ?? [])
        #expect(keys == ["requestId", "setId", "kind", "question", "searchQuery", "usedEmbedding", "hits", "status",
                         "text", "citations", "dropped", "usedJSONSchema", "latencyMs", "attempts", "model",
                         "templateFingerprint", "startedAt", "error"])
        // 값이 없는 선택 필드(problemId 등)는 빠진다. 내보내기(M6)에서 빈 칸으로 채운다.
    }

    @Test("이벤트 종류 이름 (내보내기에 그대로 쓰인다)")
    func typeNames() {
        #expect(EventType.allCases.map(\.rawValue) == [
            "app_launch", "app_quit", "app_pause", "app_resume", "problem_generated", "problem_generation_failed",
            "problem_shown", "problem_answered", "problem_skipped", "question_asked", "answer_received",
            "hint_requested", "hint_received", "citation_opened", "llm_call", "error",
        ])
    }
}
