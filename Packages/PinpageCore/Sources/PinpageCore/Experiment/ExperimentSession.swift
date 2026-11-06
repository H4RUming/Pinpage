import Foundation
import GRDB

public enum ExperimentCondition: String, Codable, CaseIterable, Sendable {
    /// AI 연습 문제·질문·힌트를 쓰는 조건
    case tool
    /// AI 기능 없이 자료 뷰어, 타이머, 체크포인트 퀴즈만
    case control

    public var label: String {
        switch self {
        case .tool: "도구"
        case .control: "대조"
        }
    }
}

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    /// 사전 퀴즈 → 학습 → 체크포인트 퀴즈 (통과할 때까지 재응시)
    case learning
    /// 최종 시험 (한 번 응시)
    case final
    /// 재시험 (한 번 응시)
    case retest

    public var label: String {
        switch self {
        case .learning: "학습"
        case .final: "최종 시험"
        case .retest: "재시험"
        }
    }

    /// 이 세션의 결과를 정하는 퀴즈.
    public var mainQuiz: QuizKind {
        switch self {
        case .learning: .checkpoint
        case .final: .final
        case .retest: .retest
        }
    }
}

public enum SessionPhase: String, Codable, Sendable {
    case preQuiz = "pre_quiz"
    case studying
    /// 체크포인트 퀴즈, 최종 시험, 재시험을 푸는 중
    case quiz
    case completed
    case abandoned

    public var isActive: Bool { self != .completed && self != .abandoned }

    /// 경과 시간을 쌓을 단계.
    public var stage: SessionStage? {
        switch self {
        case .preQuiz: .preQuiz
        case .studying: .study
        case .quiz: .quiz
        case .completed, .abandoned: nil
        }
    }
}

/// 경과 시간을 나눠 쌓는 단계.
public enum SessionStage: String, Codable, CaseIterable, Sendable {
    case preQuiz = "pre_quiz"
    case study
    case quiz
}

/// 단계별 누적 시간 (앱이 켜져 있던 시간만, 밀리초).
public struct StageTimes: Codable, Equatable, Sendable {
    public var preQuizMs = 0
    public var studyMs = 0
    /// 체크포인트 퀴즈, 최종 시험, 재시험
    public var quizMs = 0
    /// 위 시간 중 앱이 맨 앞에 있지 않았던 시간
    public var backgroundMs = 0

    public init(preQuizMs: Int = 0, studyMs: Int = 0, quizMs: Int = 0, backgroundMs: Int = 0) {
        self.preQuizMs = preQuizMs
        self.studyMs = studyMs
        self.quizMs = quizMs
        self.backgroundMs = backgroundMs
    }

    public var totalMs: Int { preQuizMs + studyMs + quizMs }
    /// 사전 퀴즈를 뺀 시간 (학습 + 퀴즈). 학습 세션에서는 "통과까지 걸린 시간"이 된다.
    public var learningMs: Int { studyMs + quizMs }

    public subscript(stage: SessionStage) -> Int {
        get {
            switch stage {
            case .preQuiz: preQuizMs
            case .study: studyMs
            case .quiz: quizMs
            }
        }
        set {
            switch stage {
            case .preQuiz: preQuizMs = newValue
            case .study: studyMs = newValue
            case .quiz: quizMs = newValue
            }
        }
    }
}

/// 실험 세션 한 번. 진행 상태와 누적 시간을 몇 초마다 저장해 강제 종료 뒤에도 이어서 진행한다.
public struct ExperimentSession: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "experimentSession"

    public var id: String
    /// 실명이 아닌 참가자 ID
    public var participantId: String
    public var condition: ExperimentCondition
    public var kind: SessionKind
    public var setId: String?
    public var quizSetId: String
    public var phase: SessionPhase
    /// 도구 조건의 연습 문제 난이도 (사전 퀴즈 전이거나 대조 조건이면 nil)
    public var practiceDifficulty: Int?
    public var preQuizMs: Int
    public var studyMs: Int
    public var quizMs: Int
    public var backgroundMs: Int
    public var startedAt: Date
    /// 마지막으로 시간을 저장한 시각 (다시 열 때 꺼져 있던 시간을 계산한다)
    public var lastSavedAt: Date
    public var endedAt: Date?
    /// passed, completed, abandoned
    public var endReason: String?
    /// 앱이 정상 종료되며 저장했으면 true (강제 종료 여부 판단)
    public var closedCleanly: Bool

    public var times: StageTimes {
        get { StageTimes(preQuizMs: preQuizMs, studyMs: studyMs, quizMs: quizMs, backgroundMs: backgroundMs) }
        set {
            preQuizMs = newValue.preQuizMs
            studyMs = newValue.studyMs
            quizMs = newValue.quizMs
            backgroundMs = newValue.backgroundMs
        }
    }
}

/// 불러온 퀴즈 파일. 파일을 옮기거나 지워도 진행 중인 세션이 이어지도록 내용을 DB에 저장한다.
public struct QuizSetRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "quizSet"

    public var id: String
    /// 파일 안의 id
    public var quizId: String
    public var title: String
    public var fileName: String
    /// 파일 내용의 SHA-256 (모든 참가자가 같은 파일을 썼는지 확인하는 값)
    public var sha256: String
    /// 파일 원문 (JSON)
    public var content: String
    public var importedAt: Date

    public func file() throws(QuizFileError) -> QuizFile {
        try QuizFile.load(Data(content.utf8))
    }
}

/// 퀴즈 응시 한 번. 답을 고칠 때마다 저장해 강제 종료 뒤에도 고른 답이 남는다.
public struct QuizAttempt: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "quizAttempt"

    public var id: Int64?
    public var sessionId: String
    public var quizKind: QuizKind
    /// 이 세션에서 같은 종류의 몇 번째 응시인지 (1부터)
    public var attemptNumber: Int
    /// 문제 id → 답 (객관식은 번호 문자열, 1부터)
    public var responses: [String: String]
    public var startedAt: Date
    /// 응시를 시작할 때 그 단계의 누적 시간 (응시에 걸린 시간 = 제출 때 누적 시간 - 이 값)
    public var stageMsAtStart: Int
    public var submittedAt: Date?
    public var activeMs: Int?
    public var earned: Int?
    public var total: Int?
    public var passed: Bool?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    static func registerExperimentMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5: 실험 세션과 퀴즈") { db in
            try db.alter(table: "practiceProblem") { t in
                t.add(column: "sessionId", .text)
            }
            try db.create(index: "practiceProblem_on_sessionId", on: "practiceProblem", columns: ["sessionId"])

            try db.create(table: "quizSet") { t in
                t.primaryKey("id", .text)
                t.column("quizId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("sha256", .text).notNull().unique()
                t.column("content", .text).notNull()
                t.column("importedAt", .datetime).notNull()
            }
            // 학습 세트나 퀴즈 파일을 지워도 세션 기록은 남도록 외래 키를 걸지 않는다.
            try db.create(table: "experimentSession") { t in
                t.primaryKey("id", .text)
                t.column("participantId", .text).notNull().indexed()
                t.column("condition", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("setId", .text)
                t.column("quizSetId", .text).notNull()
                t.column("phase", .text).notNull()
                t.column("practiceDifficulty", .integer)
                t.column("preQuizMs", .integer).notNull()
                t.column("studyMs", .integer).notNull()
                t.column("quizMs", .integer).notNull()
                t.column("backgroundMs", .integer).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("lastSavedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("endReason", .text)
                t.column("closedCleanly", .boolean).notNull()
            }
            try db.create(table: "quizAttempt") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull().indexed().references("experimentSession", onDelete: .cascade)
                t.column("quizKind", .text).notNull()
                t.column("attemptNumber", .integer).notNull()
                t.column("responses", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("stageMsAtStart", .integer).notNull()
                t.column("submittedAt", .datetime)
                t.column("activeMs", .integer)
                t.column("earned", .integer)
                t.column("total", .integer)
                t.column("passed", .boolean)
            }
        }
    }
}
