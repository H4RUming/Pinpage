import CryptoKit
import Foundation

// 실험 세션 이벤트 내용. 진행자가 모든 참가자가 같은 조건(설정, 자료, 퀴즈 파일)이었는지 확인할 수 있게 남긴다.

public struct DocumentFingerprint: Codable, Equatable, Sendable {
    public let documentId: String
    public let fileName: String
    public let sha256: String
    public let pageCount: Int

    public init(_ document: Document) {
        documentId = document.id
        fileName = document.fileName
        sha256 = document.sha256
        pageCount = document.pageCount
    }
}

public struct QuizSummary: Codable, Equatable, Sendable {
    public let kind: String
    public let questionCount: Int
    public let totalPoints: Int
}

public struct QuizSetPayload: Codable, Equatable, Sendable {
    public let quizSetId: String
    public let quizId: String
    public let title: String
    public let fileName: String
    public let sha256: String
    public let quizzes: [QuizSummary]

    public init(record: QuizSetRecord, file: QuizFile) {
        quizSetId = record.id
        quizId = record.quizId
        title = record.title
        fileName = record.fileName
        sha256 = record.sha256
        quizzes = file.quizzes.map { QuizSummary(kind: $0.kind.rawValue, questionCount: $0.questions.count, totalPoints: $0.totalPoints) }
    }
}

public struct SessionStartedPayload: Encodable, Sendable {
    public let sessionId: String
    public let participantId: String
    public let condition: String
    public let kind: String
    public let phase: String
    public let setId: String?
    public let setName: String?
    public let documents: [DocumentFingerprint]
    public let quizSet: QuizSetPayload
    public let passThreshold: Double
    /// 사전 퀴즈 없이 시작하면 설정의 난이도 (도구 조건만)
    public let practiceDifficulty: Int?
    public let model: String
    public let embedderKey: String?
    public let templateFingerprint: String?
    /// 서버 주소를 뺀 설정의 SHA-256. 참가자마다 접속 주소(로컬 IP, Tailscale)가 달라도 같은 값이면 같은 설정이다.
    public let experimentSettingsHash: String
    /// API 키는 이벤트 로그에 기록하지 않는다.
    public let settings: AppSettings

    public init(session: ExperimentSession, setName: String?, documents: [Document], quizSet: QuizSetPayload,
                settings: AppSettings, embedderKey: String?, templateFingerprint: String?) {
        sessionId = session.id
        participantId = session.participantId
        condition = session.condition.rawValue
        kind = session.kind.rawValue
        phase = session.phase.rawValue
        setId = session.setId
        self.setName = setName
        self.documents = documents.map(DocumentFingerprint.init)
        self.quizSet = quizSet
        passThreshold = settings.learning.quizPassThreshold
        practiceDifficulty = session.practiceDifficulty
        model = settings.chat.model
        self.embedderKey = embedderKey
        self.templateFingerprint = templateFingerprint
        experimentSettingsHash = settings.experimentFingerprint
        self.settings = settings
    }
}

public struct SessionResumedPayload: Codable, Equatable, Sendable {
    public let phase: String
    /// 마지막 저장부터 다시 열 때까지 (앱이 꺼져 있던 시간, 경과 시간에는 넣지 않는다)
    public let downtimeMs: Int
    /// false면 지난번에 강제 종료(또는 충돌)된 것
    public let closedCleanly: Bool
    public let times: StageTimes

    public init(session: ExperimentSession, downtimeMs: Int, closedCleanly: Bool) {
        phase = session.phase.rawValue
        self.downtimeMs = downtimeMs
        self.closedCleanly = closedCleanly
        times = session.times
    }
}

public struct SessionEndedPayload: Codable, Equatable, Sendable {
    /// passed(체크포인트 통과), completed(시험 제출), abandoned(중단)
    public let reason: String
    public let times: StageTimes
    /// 학습 세션에서 통과했으면 사전 퀴즈를 뺀 경과 시간
    public let timeToPassMs: Int?
    public let checkpointAttempts: Int

    public init(session: ExperimentSession, checkpointAttempts: Int) {
        reason = session.endReason ?? session.phase.rawValue
        times = session.times
        timeToPassMs = session.kind == .learning && session.endReason == "passed" ? session.times.learningMs : nil
        self.checkpointAttempts = checkpointAttempts
    }
}

public struct QuizStartedPayload: Codable, Equatable, Sendable {
    public let quizKind: String
    public let attemptNumber: Int
    public let quizSetSha256: String
    public let questionIds: [String]
    public let totalPoints: Int
    /// 앱을 다시 열어 풀던 응시를 이어서 여는 경우 true
    public let resumed: Bool

    public init(attempt: QuizAttempt, quiz: Quiz, quizSetSha256: String, resumed: Bool) {
        quizKind = attempt.quizKind.rawValue
        attemptNumber = attempt.attemptNumber
        self.quizSetSha256 = quizSetSha256
        questionIds = quiz.questions.map(\.id)
        totalPoints = quiz.totalPoints
        self.resumed = resumed
    }
}

public struct QuizSubmittedPayload: Codable, Equatable, Sendable {
    public let quizKind: String
    public let attemptNumber: Int
    /// 응시를 시작해 제출할 때까지 앱이 켜져 있던 시간
    public let activeMs: Int
    public let earned: Int
    public let total: Int
    public let ratio: Double
    public let threshold: Double
    public let passed: Bool
    public let unanswered: Int
    public let items: [QuizItemResult]

    public init(attempt: QuizAttempt, result: QuizResult) {
        quizKind = attempt.quizKind.rawValue
        attemptNumber = attempt.attemptNumber
        activeMs = attempt.activeMs ?? 0
        earned = result.earned
        total = result.total
        ratio = result.ratio
        threshold = result.threshold
        passed = result.passed
        unanswered = result.items.count - result.answeredCount
        items = result.items
    }
}

public struct PracticeDifficultySetPayload: Codable, Equatable, Sendable {
    public let difficulty: Int
    /// pre_quiz(사전 퀴즈 점수) 또는 settings(사전 퀴즈가 없어 설정값)
    public let source: String
    public let preQuizRatio: Double?
    public let basicBelow: Double
    public let advancedFrom: Double

    public init(difficulty: Int, source: String, preQuizRatio: Double?, policy: DifficultyPolicy) {
        self.difficulty = difficulty
        self.source = source
        self.preQuizRatio = preQuizRatio
        basicBelow = policy.basicBelow
        advancedFrom = policy.advancedFrom
    }
}

public struct DocumentOpenedPayload: Codable, Equatable, Sendable {
    public let documentId: String
    public let fileName: String
    /// list(문서 목록에서 고름) 또는 citation(근거 위치를 눌러 열림)
    public let via: String

    public init(document: Document, via: String) {
        documentId = document.id
        fileName = document.fileName
        self.via = via
    }
}

public struct DocumentSearchedPayload: Codable, Equatable, Sendable {
    public let documentId: String
    public let fileName: String
    public let query: String
    public let matchCount: Int

    public init(document: Document, query: String, matchCount: Int) {
        documentId = document.id
        fileName = document.fileName
        self.query = query
        self.matchCount = matchCount
    }
}

extension AppSettings {
    /// 서버 주소와 API 키를 뺀 설정 값의 SHA-256 (키 정렬 JSON).
    public var experimentFingerprint: String {
        var copy = self
        copy.chat.baseURL = ""
        copy.embedding.baseURL = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[.excludeSecrets] = true
        let data = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
