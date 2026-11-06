import Foundation
import GRDB

public enum SessionError: Error, LocalizedError, Equatable {
    case invalidParticipantId
    case alreadyActive
    case quizSetNotFound
    case missingQuiz(QuizKind)
    case noMaterials
    case attemptNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidParticipantId: "참가자 ID는 영문, 숫자, -, _로 1~32자여야 합니다 (실명을 쓰지 마세요)."
        case .alreadyActive: "진행 중인 세션이 있습니다. 먼저 끝내거나 중단하세요."
        case .quizSetNotFound: "퀴즈 파일을 찾을 수 없습니다. 다시 불러오세요."
        case .missingQuiz(let kind): "이 퀴즈 파일에는 \(kind.label)가 없습니다."
        case .noMaterials: "학습 세트에 색인된 자료가 없습니다. 학습 세트 탭에서 PDF를 넣고 색인하세요."
        case .attemptNotFound: "퀴즈 응시 기록을 찾을 수 없습니다."
        }
    }
}

/// 퀴즈 제출 결과와 바뀐 세션.
public struct QuizSubmission: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 사전 퀴즈 제출 → 학습 시작. 도구 조건이면 정한 난이도
        case preQuizDone(difficulty: Int?)
        case checkpointPassed
        case checkpointFailed
        /// 최종 시험·재시험 제출 → 세션 끝
        case examCompleted
    }

    public let attempt: QuizAttempt
    public let result: QuizResult
    public let session: ExperimentSession
    public let outcome: Outcome
}

/// 실험 세션과 퀴즈 응시를 DB에 저장한다. 바뀔 때마다 바로 커밋하므로 강제 종료돼도 직전 상태가 남는다.
///
/// 진행 순서:
/// - 학습: (퀴즈 파일에 사전 퀴즈가 있으면) 사전 퀴즈 → 학습 ⇄ 체크포인트 퀴즈 (통과하면 끝)
/// - 최종 시험·재시험: 퀴즈 한 번 → 끝
public struct SessionStore: Sendable {
    public let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    // MARK: - 퀴즈 파일

    /// 퀴즈 파일을 검사해 저장한다. 같은 내용의 파일을 이미 불러왔으면 그 기록을 돌려준다.
    public func importQuiz(data: Data, fileName: String) throws -> QuizSetRecord {
        let file = try QuizFile.load(data)
        let sha = QuizFile.sha256(data)
        return try database.writer.write { db in
            if let existing = try QuizSetRecord.filter(Column("sha256") == sha).fetchOne(db) { return existing }
            let record = QuizSetRecord(id: UUID().uuidString, quizId: file.id, title: file.title, fileName: fileName,
                                       sha256: sha, content: String(decoding: data, as: UTF8.self), importedAt: now())
            try record.insert(db)
            return record
        }
    }

    public func quizSets() throws -> [QuizSetRecord] {
        try database.writer.read { db in try QuizSetRecord.order(Column("importedAt").desc).fetchAll(db) }
    }

    public func quizSet(id: String) throws -> QuizSetRecord? {
        try database.writer.read { db in try QuizSetRecord.fetchOne(db, key: id) }
    }

    // MARK: - 세션

    public static func isValidParticipantId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil
    }

    /// 세션을 시작한다. 학습 세션은 사전 퀴즈가 있으면 사전 퀴즈부터, 시험 세션은 바로 퀴즈를 연다.
    /// - Parameter defaultDifficulty: 사전 퀴즈가 없을 때 도구 조건에 쓸 난이도 (설정값)
    public func start(participantId rawId: String, condition: ExperimentCondition, kind: SessionKind,
                      setId: String?, quizSetId: String, defaultDifficulty: Int) throws -> (ExperimentSession, QuizAttempt?) {
        let participantId = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidParticipantId(participantId) else { throw SessionError.invalidParticipantId }
        guard let record = try quizSet(id: quizSetId) else { throw SessionError.quizSetNotFound }
        let file = try record.file()
        guard file.quiz(kind.mainQuiz) != nil else { throw SessionError.missingQuiz(kind.mainQuiz) }
        if kind == .learning {
            guard let setId, try hasIndexedMaterials(setId: setId) else { throw SessionError.noMaterials }
        }

        let hasPreQuiz = kind == .learning && file.quiz(.pre) != nil
        let phase: SessionPhase = switch kind {
        case .learning: hasPreQuiz ? .preQuiz : .studying
        case .final, .retest: .quiz
        }
        let date = now()
        let session = ExperimentSession(
            id: UUID().uuidString, participantId: participantId, condition: condition, kind: kind, setId: setId,
            quizSetId: quizSetId, phase: phase,
            practiceDifficulty: condition == .tool && kind == .learning && !hasPreQuiz ? defaultDifficulty : nil,
            preQuizMs: 0, studyMs: 0, quizMs: 0, backgroundMs: 0, startedAt: date, lastSavedAt: date,
            endedAt: nil, endReason: nil, closedCleanly: false)

        return try database.writer.write { db in
            if try ExperimentSession.filter(Self.activePhases.contains(Column("phase"))).fetchCount(db) > 0 {
                throw SessionError.alreadyActive
            }
            try session.insert(db)
            let quizKind: QuizKind? = switch phase {
            case .preQuiz: .pre
            case .quiz: kind.mainQuiz
            default: nil
            }
            guard let quizKind else { return (session, nil) }
            return (session, try Self.insertAttempt(db, session: session, kind: quizKind, date: date))
        }
    }

    private static let activePhases = [SessionPhase.preQuiz, .studying, .quiz].map(\.rawValue)

    public func activeSession() throws -> ExperimentSession? {
        try database.writer.read { db in
            try ExperimentSession.filter(Self.activePhases.contains(Column("phase")))
                .order(Column("startedAt").desc).fetchOne(db)
        }
    }

    public func sessions(limit: Int = 50) throws -> [ExperimentSession] {
        try database.writer.read { db in
            try ExperimentSession.order(Column("startedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// 누적 시간 등을 저장한다.
    @discardableResult
    public func save(_ session: ExperimentSession) throws -> ExperimentSession {
        var updated = session
        updated.lastSavedAt = now()
        let stored = updated
        try database.writer.write { db in try stored.update(db) }
        return updated
    }

    /// 앱을 다시 열어 이어서 진행한다. 꺼져 있던 시간과, 지난번에 정상 종료했는지를 돌려준다.
    public func resume(_ session: ExperimentSession) throws -> (session: ExperimentSession, downtimeMs: Int, closedCleanly: Bool) {
        let downtime = max(0, Int(now().timeIntervalSince(session.lastSavedAt) * 1000))
        var updated = session
        updated.closedCleanly = false
        return (try save(updated), downtime, session.closedCleanly)
    }

    /// 앱이 정상 종료될 때 마지막 시간과 함께 기록한다.
    public func markClosedCleanly(_ session: ExperimentSession) throws {
        var updated = session
        updated.closedCleanly = true
        try save(updated)
    }

    /// 세션을 중단한다 (진행 중인 응시는 제출하지 않은 채로 남긴다).
    public func abandon(_ session: ExperimentSession) throws -> ExperimentSession {
        var updated = session
        updated.phase = .abandoned
        updated.endedAt = now()
        updated.endReason = "abandoned"
        return try save(updated)
    }

    // MARK: - 퀴즈 응시

    /// 제출하지 않은 응시 (퀴즈를 풀던 중 앱이 꺼졌으면 그 답을 이어서 쓴다).
    public func openAttempt(sessionId: String) throws -> QuizAttempt? {
        try database.writer.read { db in
            try QuizAttempt.filter(Column("sessionId") == sessionId && Column("submittedAt") == nil)
                .order(Column("id").desc).fetchOne(db)
        }
    }

    /// 퀴즈 단계(사전 퀴즈, 퀴즈)인데 응시가 없으면 새로 만든다. 다시 열 때 쓴다. 학습 중이면 nil.
    public func openOrCreateAttempt(for session: ExperimentSession) throws -> (attempt: QuizAttempt, resumed: Bool)? {
        let kind: QuizKind
        switch session.phase {
        case .preQuiz: kind = .pre
        case .quiz: kind = session.kind.mainQuiz
        default: return nil
        }
        return try database.writer.write { db in
            if let open = try QuizAttempt.filter(Column("sessionId") == session.id && Column("submittedAt") == nil)
                .order(Column("id").desc).fetchOne(db) {
                return (open, true)
            }
            return (try Self.insertAttempt(db, session: session, kind: kind, date: now()), false)
        }
    }

    public func attempts(sessionId: String) throws -> [QuizAttempt] {
        try database.writer.read { db in
            try QuizAttempt.filter(Column("sessionId") == sessionId).order(Column("id")).fetchAll(db)
        }
    }

    /// 학습 중 체크포인트 퀴즈를 시작한다.
    public func beginCheckpoint(_ session: ExperimentSession) throws -> (ExperimentSession, QuizAttempt) {
        guard session.kind == .learning, session.phase == .studying else { throw SessionError.attemptNotFound }
        var updated = session
        updated.phase = .quiz
        updated.lastSavedAt = now()
        let stored = updated
        let attempt = try database.writer.write { db -> QuizAttempt in
            if let open = try QuizAttempt.filter(Column("sessionId") == session.id && Column("submittedAt") == nil).fetchOne(db) {
                try stored.update(db)
                return open
            }
            try stored.update(db)
            return try Self.insertAttempt(db, session: stored, kind: .checkpoint, date: stored.lastSavedAt)
        }
        return (updated, attempt)
    }

    /// 답을 고칠 때마다 저장한다.
    public func saveResponses(attemptId: Int64, responses: [String: String]) throws {
        try database.writer.write { db in
            guard var attempt = try QuizAttempt.fetchOne(db, key: attemptId), attempt.submittedAt == nil else { return }
            attempt.responses = responses
            try attempt.update(db)
        }
    }

    /// 채점하고 세션을 다음 단계로 넘긴다. `session`은 제출 직전까지 시간을 더한 상태여야 한다.
    public func submit(attemptId: Int64, responses: [String: String], session: ExperimentSession, quiz: Quiz,
                       threshold: Double, policy: DifficultyPolicy) throws -> QuizSubmission {
        let date = now()
        return try database.writer.write { db in
            guard var attempt = try QuizAttempt.fetchOne(db, key: attemptId), attempt.submittedAt == nil,
                  attempt.sessionId == session.id else { throw SessionError.attemptNotFound }
            let result = QuizScorer.score(quiz, responses: responses, threshold: threshold)
            let stage = session.phase.stage ?? .quiz
            attempt.responses = responses
            attempt.submittedAt = date
            attempt.activeMs = max(0, session.times[stage] - attempt.stageMsAtStart)
            attempt.earned = result.earned
            attempt.total = result.total
            attempt.passed = result.passed
            try attempt.update(db)

            var updated = session
            updated.lastSavedAt = date
            let outcome: QuizSubmission.Outcome
            switch attempt.quizKind {
            case .pre:
                updated.phase = .studying
                if session.condition == .tool { updated.practiceDifficulty = policy.difficulty(forRatio: result.ratio) }
                outcome = .preQuizDone(difficulty: updated.practiceDifficulty)
            case .checkpoint:
                if result.passed {
                    updated.phase = .completed
                    updated.endedAt = date
                    updated.endReason = "passed"
                    outcome = .checkpointPassed
                } else {
                    updated.phase = .studying
                    outcome = .checkpointFailed
                }
            case .final, .retest:
                updated.phase = .completed
                updated.endedAt = date
                updated.endReason = "completed"
                outcome = .examCompleted
            }
            try updated.update(db)
            return QuizSubmission(attempt: attempt, result: result, session: updated, outcome: outcome)
        }
    }

    private static func insertAttempt(_ db: Database, session: ExperimentSession, kind: QuizKind, date: Date) throws -> QuizAttempt {
        let previous = try QuizAttempt.filter(Column("sessionId") == session.id && Column("quizKind") == kind.rawValue).fetchCount(db)
        var attempt = QuizAttempt(id: nil, sessionId: session.id, quizKind: kind, attemptNumber: previous + 1, responses: [:],
                                  startedAt: date, stageMsAtStart: session.times[kind == .pre ? .preQuiz : .quiz],
                                  submittedAt: nil, activeMs: nil, earned: nil, total: nil, passed: nil)
        try attempt.insert(db)
        return attempt
    }

    private func hasIndexedMaterials(setId: String) throws -> Bool {
        try database.writer.read { db in
            try Document.filter(Column("setId") == setId && Column("status") == DocumentStatus.indexed.rawValue).fetchCount(db) > 0
        }
    }
}
