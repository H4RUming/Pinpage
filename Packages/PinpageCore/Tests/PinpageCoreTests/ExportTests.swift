import Foundation
import GRDB
import Testing
@testable import PinpageCore

/// 저장소의 예시 퀴즈 파일 (Examples/quiz-example.json).
private let exampleQuizURL = templateDirectory
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Examples/quiz-example.json")

private let policy = DifficultyPolicy(basicBelow: 0.4, advancedFrom: 0.75)
private let secretKey = "sk-export-test-secret"

@Suite("CSV")
struct CSVTests {
    @Test("쉼표, 큰따옴표, 줄바꿈이 든 값만 감싸고 BOM과 CRLF를 쓴다")
    func escaping() {
        #expect(CSV.escape("평범한 값") == "평범한 값")
        #expect(CSV.escape("a,b") == "\"a,b\"")
        #expect(CSV.escape("그는 \"네\"라고") == "\"그는 \"\"네\"\"라고\"")
        #expect(CSV.escape("첫 줄\n둘째 줄") == "\"첫 줄\n둘째 줄\"")
        #expect(CSV.escape("a\rb") == "\"a\rb\"")
        #expect(CSV.escape("") == "")

        struct Row { let a: String; let b: Int? }
        let columns = [CSVColumn<Row>("a") { $0.a }, CSVColumn<Row>("b") { CSV.int($0.b) }]
        let data = CSV.encode([Row(a: "x,y", b: 3), Row(a: "한글", b: nil)], columns: columns)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: data, as: UTF8.self) == "\u{FEFF}a,b\r\n\"x,y\",3\r\n한글,\r\n")
        // 줄이 없어도 헤더는 같다
        #expect(String(decoding: CSV.encode([Row](), columns: columns), as: UTF8.self) == "\u{FEFF}a,b\r\n")
    }

    @Test("값 형식: 비율은 소수점 넷째 자리, 참·거짓은 true/false, 시각은 UTC 밀리초")
    func formats() {
        #expect(CSV.ratio(2.0 / 3.0) == "0.6667")
        #expect(CSV.ratio(1) == "1.0000")
        #expect(CSV.ratio(nil) == "")
        #expect(CSV.bool(true) == "true" && CSV.bool(false) == "false" && CSV.bool(nil) == "")
        #expect(CSV.time(Date(timeIntervalSince1970: 1_800_000_000.5)) == "2027-01-15T08:00:00.500Z")
    }
}

@Suite("zip")
struct ZipTests {
    @Test("CRC-32 표준 검사값")
    func crc() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipWriter.crc32(Data()) == 0)
    }

    @Test("만든 zip을 unzip이 검사하고 같은 내용으로 푼다")
    func roundTrip() throws {
        let entries = [
            ZipWriter.Entry(name: "a.txt", data: Data("안녕\n".utf8)),
            ZipWriter.Entry(name: "empty.csv", data: Data()),
            ZipWriter.Entry(name: "big.bin", data: Data((0..<70_000).map { UInt8($0 % 251) })),
        ]
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try ZipWriter.archive(entries, modified: modified, timeZone: TimeZone(identifier: "Asia/Seoul")!)
        let directory = FileManager.default.temporaryDirectory.appending(path: "pinpage-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appending(path: "test.zip")
        try data.write(to: zip)

        let test = try run("/usr/bin/unzip", ["-t", zip.path])
        #expect(test.status == 0)
        #expect(test.output.contains("No errors detected"))
        for entry in entries {
            let extracted = try run("/usr/bin/unzip", ["-p", zip.path, entry.name])
            #expect(extracted.data == entry.data, "\(entry.name)")
        }
        // 수정 시각은 지정한 시간대 기준 (2027-01-15 17:00:00 KST)
        let listing = try run("/usr/bin/unzip", ["-l", zip.path])
        #expect(listing.output.contains("01-15-2027 17:00"))
    }

    @Test("MS-DOS 시각은 2초 단위")
    func dosTime() {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 13, minute: 45, second: 59))!
        let (time, day) = ZipWriter.dosDateTime(date, timeZone: utc)
        #expect(time == UInt16(13 << 11 | 45 << 5 | 29))
        #expect(day == UInt16((2026 - 1980) << 9 | 11 << 5 | 6))
    }
}

struct ProcessOutput {
    let status: Int32
    let data: Data
    var output: String { String(decoding: data, as: UTF8.self) }
}

func run(_ executable: String, _ arguments: [String]) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessOutput(status: process.terminationStatus, data: data)
}

// MARK: - 실험 기록 픽스처

/// 실제 앱처럼 SessionStore로 세션을 진행하고, SessionModel·StudyModel이 남기는 이벤트를 같은 형식으로 남긴다.
private final class ExportFixture {
    let clock = TestClock()
    let database: AppDatabase
    let library: Library
    let store: SessionStore
    let logger: EventLogger
    let setId: String
    let record: QuizSetRecord
    let file: QuizFile
    let documents: [Document]
    var settings: AppSettings

    init() async throws {
        database = try AppDatabase.inMemory()
        library = Library(database: database,
                          filesRoot: FileManager.default.temporaryDirectory.appending(path: "pinpage-export-\(UUID().uuidString)"))
        let set = try library.createSet(name: "운영체제, 3주차")
        let pdf = try TestPDF.make(pages: [["교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 네 조건이 모두 성립할 때 생긴다."]])
        let document = try library.importPDF(from: pdf, into: set.id)
        try await DocumentIndexer(library: library).index(
            documentId: document.id,
            options: IndexingOptions(chunkSize: 800, chunkOverlap: 100, minChunkLength: 0, ocrLanguages: [], prompts: nil),
            embedder: nil)
        setId = set.id
        documents = try library.documents(inSet: set.id).map(\.document)
        let clock = clock
        store = SessionStore(database: database, now: { clock.now })
        logger = EventLogger(database: database, appVersion: "0.1.0", now: { clock.now })
        record = try store.importQuiz(data: try Data(contentsOf: exampleQuizURL), fileName: "quiz-example.json")
        file = try record.file()
        settings = AppSettings()
        settings.chat = EndpointSettings(baseURL: "http://gpu-server:8000/v1", apiKey: secretKey, model: "Qwen/Qwen3.5-27B")
    }

    func begin(_ participantId: String, _ condition: ExperimentCondition, _ kind: SessionKind) throws -> (ExperimentSession, QuizAttempt?) {
        let (session, attempt) = try store.start(participantId: participantId, condition: condition, kind: kind,
                                                 setId: kind == .learning ? setId : nil, quizSetId: record.id, defaultDifficulty: 2)
        logger.context = EventLogger.Context(sessionId: session.id, participantId: session.participantId)
        logger.log(.sessionStarted, SessionStartedPayload(
            session: session, setName: kind == .learning ? "운영체제, 3주차" : nil, documents: kind == .learning ? documents : [],
            quizSet: QuizSetPayload(record: record, file: file), settings: settings, embedderKey: nil, templateFingerprint: "tf"))
        if let attempt { quizStarted(attempt) }
        return (session, attempt)
    }

    func quizStarted(_ attempt: QuizAttempt) {
        logger.log(.quizStarted, QuizStartedPayload(attempt: attempt, quiz: file.quiz(attempt.quizKind)!,
                                                    quizSetSha256: record.sha256, resumed: false))
    }

    func submit(_ attempt: QuizAttempt, _ responses: [String: String], session: ExperimentSession) throws -> QuizSubmission {
        let submission = try store.submit(attemptId: attempt.id!, responses: responses, session: session,
                                          quiz: file.quiz(attempt.quizKind)!, threshold: 0.8, policy: policy)
        logger.log(.quizSubmitted, QuizSubmittedPayload(attempt: submission.attempt, result: submission.result))
        return submission
    }

    func end(_ session: ExperimentSession, checkpointAttempts: Int) {
        logger.log(.sessionEnded, SessionEndedPayload(session: session, checkpointAttempts: checkpointAttempts))
        logger.context = EventLogger.Context()
    }

    func problem(_ id: String) -> PracticeProblem {
        PracticeProblem(id: id, setId: setId, type: .shortAnswer, difficulty: 2, question: "교착 상태의 조건 수는?", choices: [],
                        answerIndex: nil, acceptedAnswers: ["4", "네 개"], modelAnswer: "4", keyPoints: [], sourceChunkIds: [],
                        status: .shown, createdAt: clock.now, shownAt: clock.now, model: "qwen", templateFingerprint: "tf",
                        rawResponse: "{}", latencyMs: 10)
    }

    func answered(_ problem: PracticeProblem, _ verdict: Verdict, number: Int) {
        let attempt = ProblemAttempt(id: nil, problemId: problem.id, answer: "4", verdict: verdict, score: verdict == .correct ? 1 : 0,
                                     feedback: "", missedKeyPoints: [], gradedBy: "code", rawResponse: nil, latencyMs: 0,
                                     createdAt: clock.now)
        logger.log(.problemAnswered, ProblemAnsweredPayload(problem: problem, attempt: attempt, attemptNumber: number,
                                                            elapsedMs: 5_000, missed: []))
    }

    func received(_ status: GroundedStatus, requestId: String, hintLevel: Int? = nil) {
        let result = GroundedResult(kind: hintLevel.map { .hint(level: $0) } ?? .answer, question: "교착 상태란?", problem: nil,
                                    searchQuery: "교착 상태", hits: [], usedEmbedding: false, status: status, text: "",
                                    citations: [], dropped: [], notInMaterialsReason: nil, rawResponse: "{}", reasoning: nil,
                                    usedJSONSchema: true, latencyMs: 100, attempts: 1, model: "qwen", templateFingerprint: "tf",
                                    startedAt: clock.now)
        logger.log(hintLevel == nil ? .answerReceived : .hintReceived,
                   GroundedPayload(requestId: requestId, setId: setId, problemId: nil, result: result, embedderKey: nil))
    }

    func llmCall(_ outcome: LLMCallRecord.Outcome, latency: Int, operation: LLMOperation = .chat) {
        logger.log(.llmCall, LLMCallPayload(LLMCallRecord(operation: operation, baseURL: "http://gpu-server:8000/v1", model: "qwen",
                                                          attempt: 1, outcome: outcome, latencyMs: latency, statusCode: nil,
                                                          errorCode: nil, startedAt: clock.now)))
    }

    /// 도구 조건 P01: 사전 퀴즈 2/3 → 연습·질문·힌트 → 체크포인트 3/5 실패 → 강제 종료 후 재개 → 4/5 통과
    func toolSession() throws -> ExperimentSession {
        logger.log(.appLaunch, AppStatePayload(reason: "launch"))  // 세션 밖
        var (session, pre) = try begin("P01", .tool, .learning)
        clock.advance(90)
        session.times = StageTimes(preQuizMs: 90_000)
        let preDone = try submit(pre!, ["pre-1": "3", "pre-2": "bfs", "pre-3": "1"], session: session)
        session = preDone.session
        logger.log(.practiceDifficultySet, PracticeDifficultySetPayload(difficulty: 2, source: "pre_quiz",
                                                                        preQuizRatio: preDone.result.ratio, policy: policy))

        // 연습 문제 3개: 하나는 틀렸다가 맞히고, 하나는 넘긴다
        let p1 = problem("p1"), p2 = problem("p2"), p3 = problem("p3")
        logger.log(.problemShown, ProblemShownPayload(problem: p1, number: 1))
        answered(p1, .incorrect, number: 1)
        answered(p1, .correct, number: 2)
        logger.log(.problemShown, ProblemShownPayload(problem: p2, number: 2))
        logger.log(.problemSkipped, ProblemSkippedPayload(problemId: p2.id, attempts: 0, elapsedMs: 3_000))
        logger.log(.problemShown, ProblemShownPayload(problem: p3, number: 3))
        answered(p3, .partial, number: 1)

        // 질문 2개 (하나는 자료에 없음), 힌트 1단계 2번, 2단계 1번, 3단계 1번
        for (index, status) in [GroundedStatus.answered, .notInMaterials].enumerated() {
            logger.log(.questionAsked, RequestPayload(requestId: "q\(index)", setId: setId, problemId: nil, question: "교착 상태란?", hintLevel: nil))
            received(status, requestId: "q\(index)")
        }
        for (index, level) in [1, 1, 2, 3].enumerated() {
            logger.log(.hintRequested, RequestPayload(requestId: "h\(index)", setId: setId, problemId: "p1", question: nil, hintLevel: level))
            received(.answered, requestId: "h\(index)", hintLevel: level)
        }
        logger.log(.citationOpened, CitationOpenedPayload(requestId: "q0", problemId: nil, chunk: try firstChunk(), fileName: documents[0].fileName))
        logger.log(.documentOpened, DocumentOpenedPayload(document: documents[0], via: "list"))
        logger.log(.documentSearched, DocumentSearchedPayload(document: documents[0], query: "교착", matchCount: 2))
        logger.log(.documentSearched, DocumentSearchedPayload(document: documents[0], query: "없는 말", matchCount: 0))
        logger.log(.appPause, AppStatePayload(reason: "inactive"))
        logger.log(.appResume, AppStatePayload(reason: "active"))
        llmCall(.success, latency: 300)
        llmCall(.retry, latency: 5_000)
        llmCall(.success, latency: 100)
        llmCall(.failure, latency: 9_000)
        llmCall(.success, latency: 200)
        llmCall(.success, latency: 400)
        llmCall(.success, latency: 50, operation: .embeddings)  // chat 요청만 센다

        // 체크포인트 1회차 실패
        session.times.studyMs = 600_000
        var (quizSession, attempt) = try store.beginCheckpoint(session)
        quizStarted(attempt)
        quizSession.times.quizMs = 120_000
        let failed = try submit(attempt, ["cp-1": "2", "cp-2": "mutex", "cp-3": "4"], session: quizSession)

        // 강제 종료 → 다시 열기 (학습 중)
        clock.advance(30)
        let resumed = try store.resume(failed.session)
        logger.log(.sessionResumed, SessionResumedPayload(session: resumed.session, downtimeMs: resumed.downtimeMs,
                                                          closedCleanly: resumed.closedCleanly))

        // 2회차 통과
        (quizSession, attempt) = try store.beginCheckpoint(resumed.session)
        quizStarted(attempt)
        quizSession.times.quizMs = 200_000
        clock.advance(80)
        let passed = try submit(attempt, ["cp-1": "2", "cp-2": "뮤텍스, 잠금", "cp-3": "4", "cp-4": "dfs", "cp-5": "2"],
                                session: quizSession)
        end(passed.session, checkpointAttempts: 2)
        logger.log(.appQuit, AppStatePayload(reason: "quit"))  // 세션 밖
        return passed.session
    }

    /// 대조 조건 P02: 사전 퀴즈 → 학습만 하다 중단
    func controlAbandoned() throws -> ExperimentSession {
        var (session, pre) = try begin("P02", .control, .learning)
        session.times = StageTimes(preQuizMs: 60_000)
        session = try submit(pre!, ["pre-1": "3"], session: session).session
        logger.log(.documentOpened, DocumentOpenedPayload(document: documents[0], via: "list"))
        session.times.studyMs = 300_000
        clock.advance(400)
        let abandoned = try store.abandon(session)
        end(abandoned, checkpointAttempts: 0)
        return abandoned
    }

    /// P01 최종 시험: 2점짜리 객관식만 맞힘 (2/3)
    func finalExam() throws -> ExperimentSession {
        clock.advance(3600)
        var (session, attempt) = try begin("P01", .tool, .final)
        session.times.quizMs = 240_000
        let done = try submit(attempt!, ["final-1": "4", "final-2": "뮤텍스"], session: session)
        end(done.session, checkpointAttempts: 0)
        return done.session
    }

    func firstChunk() throws -> Chunk {
        try database.writer.read { db in try Chunk.fetchOne(db)! }
    }

    func environment(model: String = "Qwen/Qwen3.5-27B") -> LogExportEnvironment {
        LogExportEnvironment(appInfo: AppInfo(version: "0.1.0", build: "7"), fallbackModel: model,
                             exportedAt: Date(timeIntervalSince1970: 1_800_100_000.25), timeZone: TimeZone(identifier: "Asia/Seoul")!,
                             osVersion: "Version 26.1")
    }
}

/// CSV를 RFC 4180대로 읽는다 (테스트 확인용).
private func parseCSV(_ data: Data) -> [[String: String]] {
    var text = String(decoding: data, as: UTF8.self)
    #expect(text.hasPrefix("\u{FEFF}"))
    text.removeFirst()
    var rows: [[String]] = [[]]
    var field = ""
    var quoted = false
    var iterator = Array(text).makeIterator()
    var pending: Character?
    while let c = pending ?? iterator.next() {
        pending = nil
        if quoted {
            if c == "\"" {
                if let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" {
            quoted = true
        } else if c == "," {
            rows[rows.count - 1].append(field); field = ""
        } else if c == "\r\n" || c == "\n" {
            rows[rows.count - 1].append(field); field = ""
            rows.append([])
        } else { field.append(c) }
    }
    if rows.last?.isEmpty == true { rows.removeLast() }
    let header = rows.removeFirst()
    return rows.map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
}

private func header(_ data: Data) -> String {
    String(String(decoding: data, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first ?? "")
}

private func file(_ export: LogExport, _ name: String) -> Data {
    export.files.first { $0.name == name }!.data
}

@Suite("로그 내보내기")
struct LogExportTests {
    @Test("세션 요약: 도구 세션의 시간, 점수, 질문, 힌트 단계, 연습 문제, LLM 요청")
    func toolSummary() async throws {
        let fixture = try await ExportFixture()
        let session = try fixture.toolSession()
        let export = try LogExporter(database: fixture.database).export(.participant("P01"), environment: fixture.environment())
        let rows = parseCSV(file(export, LogExporter.sessionsFile))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        let expected: [String: String] = [
            "participant_id": "P01", "session_id": session.id, "condition": "tool", "session_kind": "learning",
            "set_name": "운영체제, 3주차", "quiz_id": "cs-basics-example", "quiz_sha256": fixture.record.sha256,
            "app_version": "0.1.0", "model": "Qwen/Qwen3.5-27B", "settings_hash": fixture.settings.experimentFingerprint,
            "exported_at": "2027-01-16T11:46:40.250Z", "started_at": "2027-01-15T08:00:00.000Z",
            "ended_at": "2027-01-15T08:03:20.000Z", "end_reason": "passed",
            "pre_quiz_ms": "90000", "study_ms": "600000", "quiz_ms": "200000", "background_ms": "0",
            "time_to_pass_ms": "800000", "downtime_ms": "30000", "resume_count": "1", "unclean_exit_count": "1",
            "pre_quiz_earned": "2", "pre_quiz_total": "3", "pre_quiz_ratio": "0.6667", "practice_difficulty": "2",
            "checkpoint_attempts": "2", "checkpoint_passed": "true",
            "checkpoint_last_earned": "4", "checkpoint_last_total": "5", "checkpoint_last_ratio": "0.8000",
            "exam_earned": "", "exam_total": "", "exam_ratio": "", "exam_passed": "",
            "questions_asked": "2", "not_in_materials": "1",
            "hint_level_1": "2", "hint_level_2": "1", "hint_level_3": "1", "hint_level_4": "0", "hint_level_5": "0",
            "practice_shown": "3", "practice_submissions": "3", "practice_correct": "1", "practice_skipped": "1",
            "citations_opened": "1", "documents_opened": "1", "document_searches": "2",
            "app_pauses": "1", "llm_calls": "6", "llm_failures": "1", "llm_latency_ms_median": "250",
        ]
        #expect(Set(row.keys) == Set(expected.keys))
        for (key, value) in expected {
            #expect(row[key] == value, "\(key)")
        }
    }

    @Test("대조 조건 중단 세션과 시험 세션: 횟수는 0, 해당 없는 점수는 빈 칸")
    func controlAndExam() async throws {
        let fixture = try await ExportFixture()
        _ = try fixture.controlAbandoned()
        let exam = try fixture.finalExam()
        let export = try LogExporter(database: fixture.database).export(.all, environment: fixture.environment())
        let rows = parseCSV(file(export, LogExporter.sessionsFile))
        #expect(rows.map { $0["participant_id"] } == ["P02", "P01"])

        let control = rows[0]
        #expect(control["condition"] == "control")
        #expect(control["end_reason"] == "abandoned")
        #expect(control["time_to_pass_ms"] == "")
        #expect(control["practice_difficulty"] == "")
        #expect(control["pre_quiz_earned"] == "1" && control["pre_quiz_total"] == "3")
        #expect(control["checkpoint_attempts"] == "0" && control["checkpoint_passed"] == "false")
        #expect(control["checkpoint_last_ratio"] == "")
        #expect(control["questions_asked"] == "0" && control["hint_level_1"] == "0" && control["llm_calls"] == "0")
        #expect(control["llm_latency_ms_median"] == "")
        #expect(control["documents_opened"] == "1")

        let final = rows[1]
        #expect(final["session_id"] == exam.id)
        #expect(final["session_kind"] == "final")
        #expect(final["set_name"] == "")
        #expect(final["end_reason"] == "completed")
        #expect(final["exam_earned"] == "2" && final["exam_total"] == "3" && final["exam_ratio"] == "0.6667")
        #expect(final["exam_passed"] == "false")
        #expect(final["checkpoint_attempts"] == "0" && final["checkpoint_passed"] == "")
        #expect(final["quiz_ms"] == "240000")
        #expect(final["pre_quiz_earned"] == "")
    }

    @Test("문항별 응답: 제출한 응시마다 문제 순서대로, 답하지 않은 문제는 빈 응답")
    func quizItems() async throws {
        let fixture = try await ExportFixture()
        let session = try fixture.toolSession()
        let export = try LogExporter(database: fixture.database).export(.participant("P01"), environment: fixture.environment())
        let rows = parseCSV(file(export, LogExporter.quizItemsFile))
        #expect(export.quizItemCount == 3 + 5 + 5)
        #expect(rows.count == 13)
        #expect(rows.map { "\($0["quiz_kind"]!)#\($0["attempt_number"]!)" }.filter { $0 == "checkpoint#2" }.count == 5)
        #expect(rows.prefix(3).map { $0["question_id"] } == ["pre-1", "pre-2", "pre-3"])
        #expect(rows.prefix(3).map { $0["question_number"] } == ["1", "2", "3"])

        let first = rows[3]  // 체크포인트 1회차 1번
        #expect(first["session_id"] == session.id)
        #expect(first["condition"] == "tool" && first["session_kind"] == "learning" && first["quiz_id"] == "cs-basics-example")
        #expect(first["question_type"] == "multiple_choice")
        #expect(first["response"] == "2" && first["correct"] == "true" && first["points"] == "1" && first["earned"] == "1")
        #expect(first["attempt_active_ms"] == "120000")
        let unanswered = rows[6]  // 1회차 4번 (답 없음)
        #expect(unanswered["question_id"] == "cp-4" && unanswered["response"] == "" && unanswered["correct"] == "false")
        // 쉼표가 든 응답도 한 칸으로 읽힌다
        let comma = rows[9]
        #expect(comma["question_id"] == "cp-2" && comma["response"] == "뮤텍스, 잠금" && comma["correct"] == "false")
        #expect(rows[12]["submitted_at"] == "2027-01-15T08:03:20.000Z")
    }

    @Test("quiz_submitted 이벤트가 없으면 퀴즈 파일로 다시 채점한 결과가 이벤트와 같다")
    func quizItemsFallback() async throws {
        let fixture = try await ExportFixture()
        let session = try fixture.toolSession()
        let events = try fixture.logger.all(sessionId: session.id)
        let attempts = try fixture.store.attempts(sessionId: session.id)
        let logged = QuizItemRow.rows(session: session, events: events, attempts: attempts, quizSet: fixture.record)
        let recomputed = QuizItemRow.rows(session: session, events: events.filter { $0.type != EventType.quizSubmitted.rawValue },
                                          attempts: attempts, quizSet: fixture.record)
        #expect(logged.count == 13)
        #expect(logged == recomputed)
    }

    @Test("events.jsonl: 한 줄에 이벤트 하나, 맨 위 키는 항상 같은 7개, payload는 객체")
    func jsonLines() async throws {
        let fixture = try await ExportFixture()
        _ = try fixture.toolSession()
        let export = try LogExporter(database: fixture.database).export(.all, environment: fixture.environment())
        let text = String(decoding: file(export, LogExporter.eventsFile), as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == export.eventCount)
        #expect(lines.count == (try fixture.logger.all().count))
        var previous: Int64 = 0
        for line in lines {
            #expect(line.hasPrefix("{\"seq\":"))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["seq", "timestamp", "type", "sessionId", "participantId", "appVersion", "payload"])
            #expect(object["payload"] is [String: Any])
            let seq = try #require(object["seq"] as? Int64)
            #expect(seq > previous)
            previous = seq
        }
        let launch = try #require(lines.first)
        #expect(launch.contains("\"type\":\"app_launch\""))
        #expect(launch.contains("\"sessionId\":null,\"participantId\":null"))
    }

    @Test("참가자 단위로 내보내면 다른 참가자와 세션 밖 이벤트가 빠지고, 전체는 모두 담는다")
    func scope() async throws {
        let fixture = try await ExportFixture()
        let tool = try fixture.toolSession()
        let control = try fixture.controlAbandoned()
        let exam = try fixture.finalExam()
        let exporter = LogExporter(database: fixture.database)

        let participants = try exporter.participants()
        #expect(participants.map(\.id) == ["P01", "P02"])
        #expect(participants.map(\.sessionCount) == [2, 1])

        let p01 = try exporter.export(.participant("P01"), environment: fixture.environment())
        #expect(p01.manifest.sessionIds == [tool.id, exam.id])
        #expect(p01.manifest.participantIds == ["P01"])
        let p01Events = String(decoding: file(p01, LogExporter.eventsFile), as: UTF8.self)
        #expect(!p01Events.contains(control.id))
        #expect(!p01Events.contains("app_launch") && !p01Events.contains("app_quit"))
        #expect(!p01Events.contains("\"participantId\":\"P02\""))
        #expect(p01.eventCount == (try fixture.logger.all().filter { $0.participantId == "P01" }.count))

        let all = try exporter.export(.all, environment: fixture.environment())
        #expect(all.manifest.sessionIds == [tool.id, control.id, exam.id])
        #expect(all.manifest.participantIds == ["P01", "P02"])
        #expect(all.eventCount == (try fixture.logger.all().count))
        #expect(all.manifest.scope == "all" && all.manifest.participantId == nil)
        // 값이 없는 키도 null로 남아 manifest의 키 구성이 같다
        let keys = { (export: LogExport) -> Set<String> in
            Set((try! JSONSerialization.jsonObject(with: file(export, LogExporter.manifestFile)) as! [String: Any]).keys)
        }
        #expect(keys(all) == keys(p01))
        #expect(String(decoding: file(all, LogExporter.manifestFile), as: UTF8.self).contains("\"participantId\" : null"))
        #expect(String(decoding: file(all, LogExporter.manifestFile), as: UTF8.self).contains("\"columns\" : null"))

        // 기록이 없는 참가자도 열 구성은 같다
        let none = try exporter.export(.participant("P99"), environment: fixture.environment(model: "fallback"))
        #expect(none.sessionCount == 0 && none.eventCount == 0)
        #expect(none.manifest.models == ["fallback"])
        for name in [LogExporter.sessionsFile, LogExporter.quizItemsFile] {
            #expect(header(file(none, name)) == header(file(p01, name)))
            #expect(header(file(all, name)) == header(file(p01, name)))
        }
        #expect(header(file(p01, LogExporter.sessionsFile)) == "\u{FEFF}" + SessionSummary.columns.map(\.name).joined(separator: ","))
    }

    @Test("manifest: 앱·모델·시각과 파일별 SHA-256이 실제 내용과 맞고, zip에 API 키가 없다")
    func manifestAndArchive() async throws {
        let fixture = try await ExportFixture()
        _ = try fixture.toolSession()
        let export = try LogExporter(database: fixture.database).export(.participant("P01"), environment: fixture.environment())
        let manifest = export.manifest
        #expect(manifest.format == "pinpage-log" && manifest.formatVersion == 1)
        #expect(manifest.scope == "participant" && manifest.participantId == "P01")
        #expect(manifest.appVersion == "0.1.0" && manifest.appBuild == "7")
        #expect(manifest.models == ["Qwen/Qwen3.5-27B"])
        #expect(manifest.exportedAt == "2027-01-16T11:46:40.250Z")
        #expect(manifest.exportedAtLocal == "2027-01-16T20:46:40.250+09:00")
        #expect(manifest.timeZone == "Asia/Seoul" && manifest.osVersion == "Version 26.1")
        #expect(manifest.files.map(\.name) == ["events.jsonl", "sessions.csv", "quiz_items.csv"])
        for entry in manifest.files {
            let data = file(export, entry.name)
            #expect(entry.sha256 == LogExporter.sha256(data))
            #expect(entry.bytes == data.count)
        }
        #expect(manifest.files.map(\.rows) == [export.eventCount, 1, 13])
        #expect(manifest.files[1].columns == SessionSummary.columns.map(\.name))
        #expect(manifest.files[0].columns == nil)
        #expect(export.files.map(\.name) == ["manifest.json", "events.jsonl", "sessions.csv", "quiz_items.csv"])
        let decoded = try JSONDecoder().decode(LogManifest.self, from: file(export, LogExporter.manifestFile))
        #expect(decoded == manifest)

        #expect(export.suggestedFileName == "pinpage-log_P01_v0.1.0_Qwen-Qwen3.5-27B_20270116T114640Z.zip")
        let archive = try export.archive()
        #expect(archive.range(of: Data(secretKey.utf8)) == nil)
        for entry in export.files {
            #expect(entry.data.range(of: Data(secretKey.utf8)) == nil)
        }
        // zip 안 파일을 unzip으로 꺼내도 같다
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-export-\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
        #expect(try run("/usr/bin/unzip", ["-p", url.path, "sessions.csv"]).data == file(export, LogExporter.sessionsFile))

        let payload = LogExportedPayload(export: export, fileName: "x.zip", archive: archive)
        #expect(payload.sha256 == LogExporter.sha256(archive) && payload.bytes == archive.count)
        #expect(payload.scope == "participant" && payload.participantId == "P01" && payload.quizItemCount == 13)
    }

    @Test("파일 이름: 기호는 하이픈으로, 전체는 all, 시각은 UTC")
    func fileNames() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LogExporter.fileName(scope: .all, appVersion: "0.1.0", models: ["qwen"], exportedAt: date)
            == "pinpage-log_all_v0.1.0_qwen_20270115T080000Z.zip")
        #expect(LogExporter.fileName(scope: .participant("P_01"), appVersion: "1.2", models: ["a/b:c d", "gpt_4"], exportedAt: date)
            == "pinpage-log_P_01_v1.2_a-b-c-d-gpt-4_20270115T080000Z.zip")
        #expect(LogExporter.fileName(scope: .participant("P01"), appVersion: "0.1.0", models: [], exportedAt: date)
            == "pinpage-log_P01_v0.1.0_unknown-model_20270115T080000Z.zip")
        #expect(LogExporter.sanitize("큐웬/모델", allowUnderscore: false) == "")
        #expect(LogExporter.sanitize("--a..b--", allowUnderscore: false) == "a..b")
    }

    @Test("가운데 값")
    func median() {
        #expect(SessionSummary.median([]) == nil)
        #expect(SessionSummary.median([5]) == 5)
        #expect(SessionSummary.median([300, 100, 200]) == 200)
        #expect(SessionSummary.median([100, 200, 300, 400]) == 250)
        #expect(SessionSummary.median([1, 2]) == 2)
    }
}
