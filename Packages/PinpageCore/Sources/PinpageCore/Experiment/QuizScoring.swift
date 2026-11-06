import Foundation

/// 문제 하나의 채점 결과 (로그에 그대로 남는다).
public struct QuizItemResult: Codable, Equatable, Sendable {
    public let questionId: String
    public let type: String
    /// 객관식은 고른 번호(1부터), 단답형은 입력한 답. 답하지 않았으면 nil
    public let response: String?
    public let correct: Bool
    public let points: Int
    public let earned: Int
}

/// 퀴즈 한 번의 채점 결과.
public struct QuizResult: Codable, Equatable, Sendable {
    public let earned: Int
    public let total: Int
    /// earned / total (0~1)
    public let ratio: Double
    public let threshold: Double
    public let passed: Bool
    public let items: [QuizItemResult]

    public var answeredCount: Int { items.filter { $0.response != nil }.count }
}

/// 퀴즈 채점. 두 조건이 같은 기준으로 채점되도록 AI를 쓰지 않는다.
/// - 객관식: 고른 번호와 정답 번호 비교
/// - 단답형: 공백·대소문자·문장부호·호환 문자 차이를 무시하고 정답 목록과 비교 (연습 문제 단답형과 같은 규칙)
public enum QuizScorer {
    /// `responses`: 문제 id → 답 (객관식은 번호 문자열, 1부터)
    public static func score(_ quiz: Quiz, responses: [String: String], threshold: Double) -> QuizResult {
        let items = quiz.questions.map { question -> QuizItemResult in
            let raw = responses[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let response = raw.isEmpty ? nil : raw
            let correct = isCorrect(question, response: response)
            return QuizItemResult(questionId: question.id, type: question.type.rawValue, response: response,
                                  correct: correct, points: question.score, earned: correct ? question.score : 0)
        }
        let earned = items.reduce(0) { $0 + $1.earned }
        let total = quiz.totalPoints
        return QuizResult(earned: earned, total: total, ratio: total > 0 ? Double(earned) / Double(total) : 0,
                          threshold: threshold, passed: passes(earned: earned, total: total, threshold: threshold),
                          items: items)
    }

    public static func isCorrect(_ question: QuizQuestion, response: String?) -> Bool {
        guard let response = response?.trimmingCharacters(in: .whitespacesAndNewlines), !response.isEmpty else { return false }
        switch question.type {
        case .multipleChoice:
            return Int(response) == question.answer
        case .shortAnswer:
            return ProblemGrader.matches(response, question.answers ?? [])
        }
    }

    /// 통과 기준 이상인지. 5문제 중 4문제(80%)처럼 기준과 정확히 같으면 통과한다 (소수 오차 보정).
    public static func passes(earned: Int, total: Int, threshold: Double) -> Bool {
        guard total > 0 else { return false }
        return Double(earned) >= threshold * Double(total) - 1e-9
    }
}

/// 사전 퀴즈 점수로 연습 문제 난이도를 정한다.
public struct DifficultyPolicy: Codable, Equatable, Sendable {
    /// 이 비율보다 낮으면 기초(1)
    public let basicBelow: Double
    /// 이 비율 이상이면 심화(3), 그 사이는 보통(2)
    public let advancedFrom: Double

    public init(basicBelow: Double, advancedFrom: Double) {
        self.basicBelow = basicBelow
        self.advancedFrom = advancedFrom
    }

    public init(settings: LearningSettings) {
        self.init(basicBelow: settings.preQuizBasicBelow, advancedFrom: settings.preQuizAdvancedFrom)
    }

    public func difficulty(forRatio ratio: Double) -> Int {
        if ratio >= advancedFrom - 1e-9 { return 3 }
        if ratio < basicBelow - 1e-9 { return 1 }
        return 2
    }
}
