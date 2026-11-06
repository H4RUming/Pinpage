import Foundation
import GRDB
import Testing
@testable import PinpageCore

/// 저장소의 예시 퀴즈 파일 (Examples/quiz-example.json).
private let exampleQuizURL = templateDirectory
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Examples/quiz-example.json")

private func quizData(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func question(_ id: String, mc answer: Int, choices: Int = 4, points: Int? = nil) -> [String: Any] {
    var q: [String: Any] = ["id": id, "type": "multiple_choice", "prompt": "문제 \(id)",
                            "choices": (1...choices).map { "보기 \($0)" }, "answer": answer]
    if let points { q["points"] = points }
    return q
}

private func question(_ id: String, short answers: [String]) -> [String: Any] {
    ["id": id, "type": "short_answer", "prompt": "문제 \(id)", "answers": answers]
}

private func file(_ quizzes: [[String: Any]], version: Int = 1) -> [String: Any] {
    ["format": "pinpage-quiz", "formatVersion": version, "id": "t", "title": "테스트", "quizzes": quizzes]
}

private func issues(_ object: [String: Any]) -> [String] {
    do {
        _ = try QuizFile.load(quizData(object))
        return []
    } catch {
        if case .invalid(let issues) = error { return issues.map(\.description) }
        return [error.localizedDescription]
    }
}

@Suite("퀴즈 파일")
struct QuizFileTests {
    @Test("예시 파일은 검사를 통과하고, 저장했다 다시 읽어도 같다")
    func exampleFile() throws {
        let data = try Data(contentsOf: exampleQuizURL)
        let file = try QuizFile.load(data)
        #expect(file.quizzes.map(\.kind) == [.pre, .checkpoint, .final, .retest])
        #expect(file.quiz(.checkpoint)?.questions.count == 5)
        #expect(file.quiz(.final)?.totalPoints == 3)  // 배점 2 + 1
        #expect(file.quiz(.pre)?.displayTitle == "사전 퀴즈")  // 제목이 없으면 종류 이름
        #expect(try QuizFile.load(file.encoded()) == file)
        #expect(QuizFile.sha256(data).count == 64)
    }

    @Test("JSON이 아니거나 형식·버전이 다르면 알려준다")
    func wrongFiles() {
        #expect(throws: QuizFileError.notJSON) { try QuizFile.load(Data("{".utf8)) }
        #expect(throws: QuizFileError.wrongFormat) { try QuizFile.load(quizData(["format": "pinpage-settings"])) }
        #expect(throws: QuizFileError.newerFormat(2)) {
            try QuizFile.load(quizData(file([["kind": "pre", "questions": [question("a", mc: 1)]]], version: 2)))
        }
    }

    @Test("형식이 틀린 값은 위치와 함께 알려준다")
    func malformed() {
        var q = question("a", mc: 1)
        q["answer"] = "1"
        #expect(throws: QuizFileError.malformed(location: "quizzes → 1번째 → questions → 1번째 → answer", message: "정수이어야 합니다.")) {
            try QuizFile.load(quizData(file([["kind": "checkpoint", "questions": [q]]])))
        }
        #expect(throws: QuizFileError.malformed(location: "quizzes → 1번째 → kind",
                                                message: "kind는 pre, checkpoint, final, retest 중 하나여야 합니다.")) {
            try QuizFile.load(quizData(file([["kind": "midterm", "questions": [question("a", mc: 1)]]])))
        }
        #expect(throws: QuizFileError.malformed(location: "quizzes → 1번째 → questions → 1번째", message: "'prompt' 항목이 없습니다.")) {
            try QuizFile.load(quizData(file([["kind": "pre", "questions": [["id": "a", "type": "short_answer", "answers": ["x"]]]]])))
        }
    }

    @Test("잘못된 내용을 모두, 몇 번 문제인지와 함께 알려준다")
    func invalidContent() {
        let found = issues(file([
            ["kind": "checkpoint", "questions": [
                question("q1", mc: 1),
                question("q1", mc: 2),  // id 겹침
                question("q3", mc: 5),  // 정답 번호가 보기 수를 넘음
                question("q4", short: []),  // 정답 없음
                question("q5", mc: 1, points: 0),
            ]],
            ["kind": "checkpoint", "questions": [question("a", mc: 1)]],  // 같은 종류 두 번
            ["kind": "final", "questions": []],
        ]))
        #expect(found == [
            "체크포인트 퀴즈 2번 문제 (id: q1): 같은 퀴즈 안에 id가 겹칩니다.",
            "체크포인트 퀴즈 3번 문제 (id: q3): 정답 번호 5가 보기 수(4)를 벗어납니다. 번호는 1부터 셉니다.",
            "체크포인트 퀴즈 4번 문제 (id: q4): 단답형은 answers(인정할 정답 목록)가 있어야 합니다.",
            "체크포인트 퀴즈 5번 문제 (id: q5): points(배점)는 1 이상의 정수여야 합니다 (현재 0).",
            "체크포인트 퀴즈: 같은 종류(checkpoint)의 퀴즈가 두 번 이상 있습니다.",
            "최종 시험: 문제가 하나도 없습니다.",
        ])
    }

    @Test("유형에 맞지 않는 칸, 같은 보기, 문장부호뿐인 정답을 막는다")
    func mixedFields() {
        var mc = question("m", mc: 1)
        mc["answers"] = ["보기 1"]
        mc["choices"] = ["가", "가", "나"]
        var short = question("s", short: ["?!"])
        short["answer"] = 1
        let found = issues(file([["kind": "pre", "questions": [mc, short]]]))
        #expect(found == [
            "사전 퀴즈 1번 문제 (id: m): 같은 보기가 두 번 이상 있습니다.",
            "사전 퀴즈 1번 문제 (id: m): 객관식에는 answers를 쓰지 않습니다. 정답 번호는 answer에 넣으세요.",
            "사전 퀴즈 2번 문제 (id: s): 글자나 숫자가 없는 정답이 있습니다 (공백과 문장부호는 채점에서 무시합니다).",
            "사전 퀴즈 2번 문제 (id: s): 단답형에는 answer를 쓰지 않습니다. 정답은 answers 목록에 넣으세요.",
        ])
    }

    @Test("퀴즈를 바꾸거나 넣으면 종류 순서로 정렬한다")
    func replacing() throws {
        let base = QuizFile(id: "x", title: "x", quizzes: [
            Quiz(kind: .final, questions: [QuizQuestion(id: "f", type: .shortAnswer, prompt: "?", answers: ["a"])]),
            Quiz(kind: .checkpoint, questions: [QuizQuestion(id: "c", type: .shortAnswer, prompt: "?", answers: ["a"])]),
        ])
        let pre = Quiz(kind: .pre, questions: [QuizQuestion(id: "p", type: .shortAnswer, prompt: "?", answers: ["a"])])
        let replaced = base.replacing(pre).replacing(pre)
        #expect(replaced.quizzes.map(\.kind) == [.pre, .checkpoint, .final])
        #expect(replaced.validate().isEmpty)
    }
}

@Suite("퀴즈 채점")
struct QuizScoringTests {
    private let quiz = Quiz(kind: .checkpoint, questions: [
        QuizQuestion(id: "a", type: .multipleChoice, prompt: "?", choices: ["1", "2", "3"], answer: 2),
        QuizQuestion(id: "b", type: .shortAnswer, prompt: "?", answers: ["너비 우선 탐색", "BFS"], points: 2),
        QuizQuestion(id: "c", type: .shortAnswer, prompt: "?", answers: ["뮤텍스"]),
    ])

    @Test("객관식은 번호로, 단답형은 공백·대소문자·문장부호를 무시하고 채점한다")
    func scoring() {
        let result = QuizScorer.score(quiz, responses: ["a": "2", "b": " bfs. ", "c": "세마포어"], threshold: 0.8)
        #expect(result.items.map(\.correct) == [true, true, false])
        #expect(result.items.map(\.earned) == [1, 2, 0])
        #expect(result.earned == 3 && result.total == 4)
        #expect(result.ratio == 0.75)
        #expect(!result.passed)
        #expect(QuizScorer.score(quiz, responses: ["b": "너비우선탐색"], threshold: 0).items[1].correct)
    }

    @Test("답하지 않은 문제는 응답 없음, 틀림으로 기록한다")
    func unanswered() {
        let result = QuizScorer.score(quiz, responses: ["a": "  ", "c": "뮤텍스"], threshold: 0.5)
        #expect(result.items.map(\.response) == [nil, nil, "뮤텍스"])
        #expect(result.answeredCount == 1)
        #expect(result.earned == 1)
    }

    @Test("통과 기준과 정확히 같으면 통과한다 (소수 오차 보정)")
    func passBoundary() {
        #expect(QuizScorer.passes(earned: 4, total: 5, threshold: 0.8))
        #expect(QuizScorer.passes(earned: 7, total: 10, threshold: 0.7))  // 0.7 * 10 = 7.000000000000001
        #expect(QuizScorer.passes(earned: 3, total: 10, threshold: 0.3))
        #expect(!QuizScorer.passes(earned: 3, total: 5, threshold: 0.8))
        #expect(!QuizScorer.passes(earned: 0, total: 0, threshold: 0))
        #expect(QuizScorer.passes(earned: 0, total: 5, threshold: 0))
    }

    @Test("사전 퀴즈 점수로 난이도를 정한다 (경계값은 위쪽 난이도)")
    func difficulty() {
        let policy = DifficultyPolicy(settings: LearningSettings())
        #expect(policy.basicBelow == 0.4 && policy.advancedFrom == 0.75)
        #expect(policy.difficulty(forRatio: 0) == 1)
        #expect(policy.difficulty(forRatio: 0.39) == 1)
        #expect(policy.difficulty(forRatio: 2.0 / 5.0) == 2)
        #expect(policy.difficulty(forRatio: 0.7) == 2)
        #expect(policy.difficulty(forRatio: 3.0 / 4.0) == 3)
        #expect(policy.difficulty(forRatio: 1) == 3)
    }
}

@Suite("세션 시간")
struct SessionTimerTests {
    @Test("단계별로 시간을 쌓고, 맨 앞이 아니었던 시간을 따로 쌓는다")
    func stages() {
        var timer = SessionTimer()
        #expect(timer.tick(at: 5, stage: .study, foreground: true) == 0)  // 시작 전에는 세지 않는다
        timer.start(at: 100)
        #expect(timer.tick(at: 101.5, stage: .preQuiz, foreground: true) == 1500)
        timer.tick(at: 104, stage: .study, foreground: true)
        timer.tick(at: 110, stage: .study, foreground: false)
        timer.tick(at: 111, stage: .quiz, foreground: true)
        #expect(timer.times == StageTimes(preQuizMs: 1500, studyMs: 8500, quizMs: 1000, backgroundMs: 6000))
        #expect(timer.times.totalMs == 11000)
        #expect(timer.times.learningMs == 9500)
    }

    @Test("멈춘 동안(잠자기, 앱 종료)은 더하지 않는다")
    func paused() {
        var timer = SessionTimer(times: StageTimes(studyMs: 60_000))  // 저장해 둔 시간에서 이어서
        timer.start(at: 10)
        timer.stop(at: 12, stage: .study, foreground: true)
        #expect(!timer.isRunning)
        #expect(timer.tick(at: 500, stage: .study, foreground: true) == 0)
        timer.start(at: 900)
        timer.tick(at: 901, stage: .study, foreground: true)
        #expect(timer.times.studyMs == 63_000)
    }

    @Test("tick을 아무리 자주 해도 오차가 쌓이지 않는다")
    func noDrift() {
        var timer = SessionTimer()
        timer.start(at: 1000.0004)
        var uptime = 1000.0004
        for _ in 0..<3000 {
            uptime += 1.0 / 30.0
            timer.tick(at: uptime, stage: .study, foreground: true)
        }
        #expect(timer.times.studyMs == Int((uptime * 1000).rounded(.down)) - 1_000_000)
        #expect(abs(timer.times.studyMs - 100_000) <= 1)
    }
}

/// 색인된 문서 하나가 있는 학습 세트와 예시 퀴즈 파일.
private func experimentFixture(clock: TestClock = TestClock()) async throws -> (SessionStore, Library, String, QuizSetRecord) {
    let database = try AppDatabase.inMemory()
    let library = Library(database: database,
                          filesRoot: FileManager.default.temporaryDirectory.appending(path: "pinpage-exp-\(UUID().uuidString)"))
    let set = try library.createSet(name: "CS")
    let pdf = try TestPDF.make(pages: [["교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 네 조건이 모두 성립할 때 생긴다."]])
    let document = try library.importPDF(from: pdf, into: set.id)
    try await DocumentIndexer(library: library).index(
        documentId: document.id,
        options: IndexingOptions(chunkSize: 800, chunkOverlap: 100, minChunkLength: 0, ocrLanguages: [], prompts: nil),
        embedder: nil)
    let store = SessionStore(database: database, now: { clock.now })
    let record = try store.importQuiz(data: try Data(contentsOf: exampleQuizURL), fileName: "quiz-example.json")
    return (store, library, set.id, record)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private let policy = DifficultyPolicy(basicBelow: 0.4, advancedFrom: 0.75)

@Suite("실험 세션 저장")
struct SessionStoreTests {
    @Test("같은 퀴즈 파일을 다시 불러오면 기록을 새로 만들지 않는다")
    func importOnce() async throws {
        let (store, _, _, record) = try await experimentFixture()
        let again = try store.importQuiz(data: try Data(contentsOf: exampleQuizURL), fileName: "다른 이름.json")
        #expect(again.id == record.id)
        #expect(try store.quizSets().count == 1)
        #expect(throws: QuizFileError.wrongFormat) { try store.importQuiz(data: Data("{}".utf8), fileName: "x.json") }
    }

    @Test("시작 조건을 검사한다: 참가자 ID, 진행 중인 세션, 퀴즈 종류, 색인된 자료")
    func startChecks() async throws {
        let (store, library, setId, record) = try await experimentFixture()
        #expect(SessionStore.isValidParticipantId("P01_a-2"))
        #expect(!SessionStore.isValidParticipantId("홍길동"))
        #expect(!SessionStore.isValidParticipantId("P 01"))
        #expect(throws: SessionError.invalidParticipantId) {
            try store.start(participantId: "김철수", condition: .tool, kind: .learning, setId: setId, quizSetId: record.id, defaultDifficulty: 2)
        }
        let empty = try library.createSet(name: "빈 세트")
        #expect(throws: SessionError.noMaterials) {
            try store.start(participantId: "P01", condition: .tool, kind: .learning, setId: empty.id, quizSetId: record.id, defaultDifficulty: 2)
        }
        let noRetest = try store.importQuiz(data: quizData(file([["kind": "checkpoint", "questions": [question("a", mc: 1)]]])),
                                            fileName: "cp.json")
        #expect(throws: SessionError.missingQuiz(.retest)) {
            try store.start(participantId: "P01", condition: .tool, kind: .retest, setId: nil, quizSetId: noRetest.id, defaultDifficulty: 2)
        }
        _ = try store.start(participantId: " P01 ", condition: .tool, kind: .learning, setId: setId, quizSetId: record.id, defaultDifficulty: 2)
        #expect(try store.activeSession()?.participantId == "P01")  // 앞뒤 공백 제거
        #expect(throws: SessionError.alreadyActive) {
            try store.start(participantId: "P02", condition: .control, kind: .final, setId: nil, quizSetId: record.id, defaultDifficulty: 2)
        }
    }

    @Test("도구 조건 학습: 사전 퀴즈 → 난이도 결정 → 체크포인트 실패 → 재응시 통과")
    func toolLearningFlow() async throws {
        let clock = TestClock()
        let (store, _, setId, record) = try await experimentFixture(clock: clock)
        let file = try record.file()
        let started = try store.start(participantId: "P01", condition: .tool, kind: .learning, setId: setId,
                                      quizSetId: record.id, defaultDifficulty: 2)
        var session = started.0
        let pre = started.1
        #expect(session.phase == .preQuiz)
        #expect(session.practiceDifficulty == nil)
        let preAttempt = try #require(pre)
        #expect(preAttempt.quizKind == .pre && preAttempt.attemptNumber == 1)

        // 사전 퀴즈 3문제 중 2문제 정답 (67%) → 보통(2)
        session.times = StageTimes(preQuizMs: 90_000)
        let preResult = try store.submit(attemptId: preAttempt.id!, responses: ["pre-1": "3", "pre-2": "bfs", "pre-3": "1"],
                                         session: session, quiz: file.quiz(.pre)!, threshold: 0.8, policy: policy)
        #expect(preResult.outcome == .preQuizDone(difficulty: 2))
        #expect(preResult.attempt.activeMs == 90_000)
        #expect(preResult.result.earned == 2)
        session = preResult.session
        #expect(session.phase == .studying && session.practiceDifficulty == 2)

        // 체크포인트 1회차: 3/5 → 실패, 학습으로 돌아간다
        session.times.studyMs = 600_000
        var (quizSession, attempt) = try store.beginCheckpoint(session)
        #expect(quizSession.phase == .quiz && attempt.attemptNumber == 1 && attempt.stageMsAtStart == 0)
        quizSession.times.quizMs = 120_000
        let failed = try store.submit(attemptId: attempt.id!, responses: ["cp-1": "2", "cp-2": "mutex", "cp-3": "4"],
                                      session: quizSession, quiz: file.quiz(.checkpoint)!, threshold: 0.8, policy: policy)
        #expect(failed.outcome == .checkpointFailed)
        #expect(failed.session.phase == .studying)
        #expect(failed.session.practiceDifficulty == 2)  // 체크포인트는 난이도를 바꾸지 않는다

        // 2회차: 4/5 = 80% → 통과, 세션 끝
        (quizSession, attempt) = try store.beginCheckpoint(failed.session)
        #expect(attempt.attemptNumber == 2 && attempt.stageMsAtStart == 120_000)
        quizSession.times.quizMs = 200_000
        clock.advance(10)
        let passed = try store.submit(attemptId: attempt.id!,
                                      responses: ["cp-1": "2", "cp-2": "뮤텍스", "cp-3": "4", "cp-4": "dfs", "cp-5": "1"],
                                      session: quizSession, quiz: file.quiz(.checkpoint)!, threshold: 0.8, policy: policy)
        #expect(passed.outcome == .checkpointPassed)
        #expect(passed.attempt.activeMs == 80_000)
        #expect(passed.session.phase == .completed && passed.session.endReason == "passed")
        #expect(passed.session.endedAt == clock.now)
        #expect(try store.activeSession() == nil)
        #expect(try store.attempts(sessionId: session.id).map(\.quizKind) == [.pre, .checkpoint, .checkpoint])

        let ended = SessionEndedPayload(session: passed.session, checkpointAttempts: 2)
        #expect(ended.timeToPassMs == 800_000)  // 학습 600초 + 퀴즈 200초 (사전 퀴즈 제외)
        #expect(ended.reason == "passed")
        // 이미 제출한 응시는 다시 제출할 수 없다
        #expect(throws: SessionError.attemptNotFound) {
            try store.submit(attemptId: attempt.id!, responses: [:], session: passed.session, quiz: file.quiz(.checkpoint)!,
                             threshold: 0.8, policy: policy)
        }
    }

    @Test("대조 조건은 난이도를 정하지 않고, 사전 퀴즈가 없으면 바로 학습한다")
    func controlAndNoPreQuiz() async throws {
        let (store, _, setId, record) = try await experimentFixture()
        let quizFile = try record.file()
        let (control, pre) = try store.start(participantId: "C01", condition: .control, kind: .learning, setId: setId,
                                             quizSetId: record.id, defaultDifficulty: 2)
        let submitted = try store.submit(attemptId: pre!.id!, responses: [:], session: control, quiz: quizFile.quiz(.pre)!,
                                         threshold: 0.8, policy: policy)
        #expect(submitted.outcome == .preQuizDone(difficulty: nil))
        #expect(submitted.session.practiceDifficulty == nil)
        _ = try store.abandon(submitted.session)

        let noPre = try store.importQuiz(data: quizData(file([["kind": "checkpoint", "questions": [question("a", mc: 1)]]])),
                                         fileName: "cp.json")
        let (tool, attempt) = try store.start(participantId: "T01", condition: .tool, kind: .learning, setId: setId,
                                              quizSetId: noPre.id, defaultDifficulty: 3)
        #expect(attempt == nil)
        #expect(tool.phase == .studying && tool.practiceDifficulty == 3)
    }

    @Test("최종 시험은 바로 퀴즈를 열고, 한 번 제출하면 통과 여부와 관계없이 끝난다")
    func finalExam() async throws {
        let (store, _, _, record) = try await experimentFixture()
        let (session, open) = try store.start(participantId: "P01", condition: .control, kind: .final, setId: nil,
                                              quizSetId: record.id, defaultDifficulty: 2)
        #expect(session.phase == .quiz)
        let attempt = try #require(open)
        #expect(attempt.quizKind == .final)
        let result = try store.submit(attemptId: attempt.id!, responses: ["final-1": "1", "final-2": "세마포어"],
                                      session: session, quiz: try record.file().quiz(.final)!, threshold: 0.8, policy: policy)
        #expect(result.outcome == .examCompleted)
        #expect(result.result.earned == 1 && result.result.total == 3 && !result.result.passed)
        #expect(result.session.phase == .completed && result.session.endReason == "completed")
        #expect(SessionEndedPayload(session: result.session, checkpointAttempts: 0).timeToPassMs == nil)
    }

    @Test("강제 종료 뒤 다시 열면 단계, 누적 시간, 고르던 답이 그대로이고 꺼져 있던 시간을 알려준다")
    func recovery() async throws {
        let clock = TestClock()
        let (store, _, setId, record) = try await experimentFixture(clock: clock)
        let started = try store.start(participantId: "P01", condition: .tool, kind: .learning, setId: setId,
                                      quizSetId: record.id, defaultDifficulty: 2)
        var session = started.0
        let pre = started.1
        session.times = StageTimes(preQuizMs: 42_000, backgroundMs: 1_000)
        try store.save(session)
        try store.saveResponses(attemptId: pre!.id!, responses: ["pre-1": "2"])
        try store.saveResponses(attemptId: pre!.id!, responses: ["pre-1": "3", "pre-2": "BFS"])
        clock.advance(300)  // 5분 동안 꺼져 있음 (정상 종료 표시 없음 = 강제 종료)

        let restored = try #require(try store.activeSession())
        #expect(restored.phase == .preQuiz && restored.times == session.times)
        let resumed = try store.resume(restored)
        #expect(resumed.downtimeMs == 300_000)
        #expect(!resumed.closedCleanly)
        let open = try #require(try store.openAttempt(sessionId: session.id))
        #expect(open.id == pre!.id && open.responses == ["pre-1": "3", "pre-2": "BFS"])
        let reopened = try #require(try store.openOrCreateAttempt(for: resumed.session))
        #expect(reopened.resumed && reopened.attempt.id == pre!.id)

        // 정상 종료 후 다시 열기
        try store.markClosedCleanly(resumed.session)
        clock.advance(60)
        let second = try store.resume(try #require(try store.activeSession()))
        #expect(second.closedCleanly && second.downtimeMs == 60_000)
        #expect(try store.activeSession()?.closedCleanly == false)  // 다음 강제 종료를 알아챌 수 있게 다시 false
    }

    @Test("체크포인트를 풀던 중 꺼졌으면 같은 응시를 다시 연다")
    func resumeCheckpoint() async throws {
        let (store, _, setId, record) = try await experimentFixture()
        let noPre = try store.importQuiz(data: quizData(file([["kind": "checkpoint", "questions": [question("a", mc: 1)]]])),
                                         fileName: "cp.json")
        _ = record
        let (session, _) = try store.start(participantId: "P01", condition: .tool, kind: .learning, setId: setId,
                                           quizSetId: noPre.id, defaultDifficulty: 2)
        #expect(try store.openOrCreateAttempt(for: session) == nil)  // 학습 중에는 응시가 없다
        let (quizSession, attempt) = try store.beginCheckpoint(session)
        var studying = quizSession
        studying.phase = .studying  // 화면이 아직 학습 상태로 알고 있어도
        let (_, again) = try store.beginCheckpoint(studying)
        #expect(again.id == attempt.id)
        #expect(try store.attempts(sessionId: session.id).count == 1)
    }
}

@Suite("실험 세션 이벤트")
struct SessionPayloadTests {
    @Test("세션 시작 기록에 API 키가 들어가지 않고, 설정 해시는 서버 주소와 무관하다")
    func startedPayload() async throws {
        let (store, library, setId, record) = try await experimentFixture()
        let (session, _) = try store.start(participantId: "P01", condition: .tool, kind: .learning, setId: setId,
                                           quizSetId: record.id, defaultDifficulty: 2)
        var settings = AppSettings()
        settings.chat = EndpointSettings(baseURL: "http://gpu-server:8000", apiKey: "sk-secret-123", model: "qwen")
        let payload = SessionStartedPayload(
            session: session, setName: "CS", documents: try library.documents(inSet: setId).map(\.document),
            quizSet: QuizSetPayload(record: record, file: try record.file()), settings: settings,
            embedderKey: nil, templateFingerprint: "abc")
        let json = try EventLogger.encode(payload)
        #expect(!json.contains("sk-secret-123"))
        #expect(!json.contains("apiKey"))
        #expect(json.contains("\"model\":\"qwen\""))
        #expect(json.contains(record.sha256))
        #expect(payload.documents.count == 1 && payload.documents[0].sha256.count == 64)

        var otherAddress = settings
        otherAddress.chat.baseURL = "100.100.10.20:8000"
        otherAddress.chat.apiKey = ""
        #expect(otherAddress.experimentFingerprint == settings.experimentFingerprint)
        var otherModel = settings
        otherModel.chat.model = "qwen3.5-27b"
        #expect(otherModel.experimentFingerprint != settings.experimentFingerprint)
    }

    @Test("퀴즈 제출 기록에 문제별 응답과 정답 여부, 걸린 시간이 남는다")
    func submittedPayload() throws {
        let quiz = Quiz(kind: .checkpoint, questions: [
            QuizQuestion(id: "a", type: .multipleChoice, prompt: "?", choices: ["1", "2"], answer: 1),
            QuizQuestion(id: "b", type: .shortAnswer, prompt: "?", answers: ["x"]),
        ])
        let result = QuizScorer.score(quiz, responses: ["a": "1"], threshold: 0.8)
        let attempt = QuizAttempt(id: 1, sessionId: "s", quizKind: .checkpoint, attemptNumber: 2, responses: ["a": "1"],
                                  startedAt: Date(), stageMsAtStart: 0, submittedAt: Date(), activeMs: 31_000,
                                  earned: 1, total: 2, passed: false)
        let json = try EventLogger.encode(QuizSubmittedPayload(attempt: attempt, result: result))
        #expect(json.contains("\"activeMs\":31000"))
        #expect(json.contains("\"attemptNumber\":2"))
        #expect(json.contains("\"unanswered\":1"))
        #expect(json.contains("{\"correct\":true,\"earned\":1,\"points\":1,\"questionId\":\"a\",\"response\":\"1\",\"type\":\"multiple_choice\"}"))
    }
}

/// 무작위 선택 함수가 받은 후보 수를 기록한다 (0번째를 고른다).
private final class PoolSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    var values: [Int] { lock.withLock { sizes } }
    func append(_ size: Int) -> Int {
        lock.withLock { sizes.append(size) }
        return 0
    }
}

@Suite("연습 문제와 세션")
struct PracticeSessionScopeTests {
    @Test("세션 안에서는 그 세션에서 낸 문제만 보고 출제 위치를 고른다")
    func scopedTargets() async throws {
        let (_, library, setId, _) = try await experimentFixture()
        let pdf = try TestPDF.make(pages: [["경쟁 상태는 여러 스레드가 공유 데이터에 동시에 접근할 때 실행 순서에 따라 결과가 달라지는 문제다. 뮤텍스로 막는다."]])
        let second = try library.importPDF(from: pdf, into: setId)
        try await DocumentIndexer(library: library).index(
            documentId: second.id,
            options: IndexingOptions(chunkSize: 800, chunkOverlap: 100, minChunkLength: 0, ocrLanguages: [], prompts: nil),
            embedder: nil)
        let chunks = try await library.database.writer.read { db in try Chunk.fetchAll(db) }
        let first = try #require(chunks.first { $0.documentId != second.id })
        // 세션 밖에서 첫 청크로 문제를 하나 냈다.
        let problem = PracticeProblem(
            id: "p1", setId: setId, type: .shortAnswer, difficulty: 2, question: "?", choices: [], answerIndex: nil,
            acceptedAnswers: ["x"], modelAnswer: "x", keyPoints: [], sourceChunkIds: [first.id!], status: .shown,
            createdAt: Date(), shownAt: nil, model: "m", templateFingerprint: "f", rawResponse: "", latencyMs: 0)
        try await library.database.writer.write { db in try problem.insert(db) }

        let poolSizes = PoolSizes()
        let generator = ProblemGenerator(database: library.database, client: OpenAIClient(endpoint: try APIEndpoint(baseURL: "gpu-server:8000"),
                                                                                  timeoutSeconds: 10, retryPolicy: RetryPolicy(maxRetries: 0)),
                                         templates: try realTemplates(),
                                         request: StructuredRequest(model: "m", temperature: 0, maxTokens: 64, enforceJSONSchema: false, extraBody: [:]),
                                         random: { poolSizes.append($0) })
        // 세션 밖: 첫 청크는 이미 냈으므로 나머지 청크 중에서 고른다
        #expect(try generator.pickTarget(setId: setId, excluding: [])?.chunk.id != first.id)
        // 새 세션: 세션 밖 문제는 보지 않으므로 모든 청크가 후보
        _ = try generator.pickTarget(setId: setId, sessionId: "S1", excluding: [])
        #expect(poolSizes.values == [chunks.count - 1, chunks.count])
    }
}

extension ChatStubbed {
    @Suite("사전 퀴즈 만들기")
    struct PreQuizBuilderTests {
        private func json(_ object: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        @Test("고르게 떨어진 위치를 고른다")
        func spread() {
            #expect(PreQuizBuilder.spreadIndices(count: 3, in: 9) == [1, 4, 7])
            #expect(PreQuizBuilder.spreadIndices(count: 2, in: 3) == [0, 2])
            #expect(PreQuizBuilder.spreadIndices(count: 5, in: 2) == [0, 1])
            #expect(PreQuizBuilder.spreadIndices(count: 0, in: 4) == [])
        }

        @Test("temperature 0으로 유형과 난이도를 번갈아 만들고, 정답 번호를 1부터 센 퀴즈 문제로 바꾼다")
        func build() async throws {
            let (_, library, setId, _) = try await experimentFixture()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChatServerStub.self]
            let client = OpenAIClient(endpoint: try APIEndpoint(baseURL: "gpu-server:8000"), timeoutSeconds: 10,
                                      retryPolicy: RetryPolicy(maxRetries: 0), session: URLSession(configuration: configuration))
            let quote = "네 조건이 모두 성립할 때 생긴다."
            ChatServerStub.queue([
                .content(json(["status": "ok", "question": "교착 상태가 생기는 조건이 아닌 것은?",
                               "choices": ["상호 배제", "점유 대기", "선점 가능", "순환 대기"], "answer_index": 2,
                               "accepted_answers": [], "model_answer": "",
                               "key_points": [["point": "네 조건", "source": 1, "quote": quote]]])),
                .content(json(["answerable": true, "answer": 3])),
            ])
            let builder = PreQuizBuilder(database: library.database, client: client, templates: try realTemplates(),
                                         request: StructuredRequest(model: "qwen", temperature: 0.7, maxTokens: 512,
                                                                    enforceJSONSchema: true, extraBody: [:]))
            let output = try await builder.build(setId: setId, count: 1, types: [.multipleChoice, .shortAnswer])
            let draft = try #require(output.drafts.first)
            #expect(draft.question.id == "pre-1")
            #expect(draft.question.type == .multipleChoice)
            #expect(draft.question.answer == 3)
            #expect(draft.question.source?.contains("1쪽") == true)
            #expect(draft.difficulty == 1)
            #expect(draft.quotes == [quote])
            let body = try #require(ChatServerStub.requests.first)
            #expect(body["temperature"] as? Double == 0)
            let system = (body["messages"] as? [[String: String]])?[0]["content"] ?? ""
            #expect(system.contains("사전 퀴즈"))

            let quiz = Quiz(kind: .pre, questions: output.drafts.map(\.question))
            #expect(QuizFile(id: "x", title: "x", quizzes: [quiz]).validate().isEmpty)
        }
    }
}
