import Foundation
import GRDB

public enum ProblemType: String, Codable, CaseIterable, Sendable {
    case multipleChoice = "multiple_choice"
    case shortAnswer = "short_answer"
    case essay

    public var label: String {
        switch self {
        case .multipleChoice: "객관식"
        case .shortAnswer: "단답형"
        case .essay: "서술형"
        }
    }
}

/// 채점 기준이 되는 요점. 반드시 자료의 근거(청크와 인용)를 가진다.
public struct KeyPoint: Codable, Equatable, Sendable {
    public var text: String
    public var chunkId: Int64
    public var quote: String

    public init(text: String, chunkId: Int64, quote: String) {
        self.text = text
        self.chunkId = chunkId
        self.quote = quote
    }
}

public enum ProblemStatus: String, Codable, Sendable {
    /// 만들어 두었지만 아직 보여주지 않음 (미리 만든 다음 문제)
    case generated
    case shown
    /// 맞힘
    case solved
    case skipped
}

/// AI가 학습 자료에서 만든 연습 문제.
public struct PracticeProblem: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "practiceProblem"

    public var id: String
    public var setId: String
    public var type: ProblemType
    /// 1 기초, 2 보통, 3 심화
    public var difficulty: Int
    public var question: String
    /// 객관식 보기
    public var choices: [String]
    /// 객관식 정답 번호 (0부터)
    public var answerIndex: Int?
    /// 단답형 정답들 (하나라도 같으면 정답)
    public var acceptedAnswers: [String]
    /// 모범 답안 (3단계 힌트와 채점에 쓴다)
    public var modelAnswer: String
    public var keyPoints: [KeyPoint]
    /// 문제를 만들 때 준 근거 청크
    public var sourceChunkIds: [Int64]
    public var status: ProblemStatus
    public var createdAt: Date
    public var shownAt: Date?
    public var model: String
    public var templateFingerprint: String
    public var rawResponse: String
    public var latencyMs: Int

    /// 힌트와 질문에 넣는 문제 문구 (객관식이면 보기 포함).
    public var promptText: String {
        guard type == .multipleChoice, !choices.isEmpty else { return question }
        let list = choices.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
        return "\(question)\n\(list)"
    }
}

public enum Verdict: String, Codable, Sendable {
    case correct
    case partial
    case incorrect

    public var label: String {
        switch self {
        case .correct: "맞음"
        case .partial: "부분 정답"
        case .incorrect: "틀림"
        }
    }
}

/// 답안 제출 한 번.
public struct ProblemAttempt: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "problemAttempt"

    public var id: Int64?
    public var problemId: String
    /// 객관식은 고른 번호(0부터)를 문자열로, 나머지는 답안 원문
    public var answer: String
    public var verdict: Verdict
    /// 0~1
    public var score: Double
    public var feedback: String
    /// 빠진 요점 번호 (0부터, keyPoints 기준)
    public var missedKeyPoints: [Int]
    /// "code" 또는 "ai"
    public var gradedBy: String
    public var rawResponse: String?
    public var latencyMs: Int
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension AppDatabase {
    static func registerProblemMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4: 연습 문제와 답안") { db in
            try db.create(table: "practiceProblem") { t in
                t.primaryKey("id", .text)
                t.column("setId", .text).notNull().indexed().references("learningSet", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("difficulty", .integer).notNull()
                t.column("question", .text).notNull()
                t.column("choices", .text).notNull()
                t.column("answerIndex", .integer)
                t.column("acceptedAnswers", .text).notNull()
                t.column("modelAnswer", .text).notNull()
                t.column("keyPoints", .text).notNull()
                t.column("sourceChunkIds", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("shownAt", .datetime)
                t.column("model", .text).notNull()
                t.column("templateFingerprint", .text).notNull()
                t.column("rawResponse", .text).notNull()
                t.column("latencyMs", .integer).notNull()
            }
            try db.create(table: "problemAttempt") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("problemId", .text).notNull().indexed().references("practiceProblem", onDelete: .cascade)
                t.column("answer", .text).notNull()
                t.column("verdict", .text).notNull()
                t.column("score", .double).notNull()
                t.column("feedback", .text).notNull()
                t.column("missedKeyPoints", .text).notNull()
                t.column("gradedBy", .text).notNull()
                t.column("rawResponse", .text)
                t.column("latencyMs", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
    }
}
