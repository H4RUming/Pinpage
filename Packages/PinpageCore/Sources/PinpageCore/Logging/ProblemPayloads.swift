import Foundation

// 연습 문제 이벤트 내용. 참가자마다 문제가 다를 수 있으므로 문제 전문을 모두 남긴다.

public struct KeyPointPayload: Codable, Equatable, Sendable {
    public let text: String
    public let chunkId: Int64
    public let quote: String

    public init(_ point: KeyPoint) {
        text = point.text
        chunkId = point.chunkId
        quote = point.quote
    }
}

/// 문제 전문.
public struct ProblemPayload: Codable, Equatable, Sendable {
    public let problemId: String
    public let setId: String
    public let type: String
    public let difficulty: Int
    public let question: String
    public let choices: [String]
    public let answerIndex: Int?
    public let acceptedAnswers: [String]
    public let modelAnswer: String
    public let keyPoints: [KeyPointPayload]
    public let sourceChunkIds: [Int64]

    public init(_ problem: PracticeProblem) {
        problemId = problem.id
        setId = problem.setId
        type = problem.type.rawValue
        difficulty = problem.difficulty
        question = problem.question
        choices = problem.choices
        answerIndex = problem.answerIndex
        acceptedAnswers = problem.acceptedAnswers
        modelAnswer = problem.modelAnswer
        keyPoints = problem.keyPoints.map(KeyPointPayload.init)
        sourceChunkIds = problem.sourceChunkIds
    }
}

public struct ProblemGeneratedPayload: Codable, Equatable, Sendable {
    public let problem: ProblemPayload
    public let model: String
    public let templateFingerprint: String
    public let latencyMs: Int
    public let rawResponse: String

    public init(problem: PracticeProblem) {
        self.problem = ProblemPayload(problem)
        model = problem.model
        templateFingerprint = problem.templateFingerprint
        latencyMs = problem.latencyMs
        rawResponse = problem.rawResponse
    }
}

public struct ProblemGenerationFailedPayload: Codable, Equatable, Sendable {
    public let setId: String
    public let failures: [ProblemGenerationFailure]

    public init(setId: String, failures: [ProblemGenerationFailure]) {
        self.setId = setId
        self.failures = failures
    }
}

public struct ProblemShownPayload: Codable, Equatable, Sendable {
    /// 이 화면에서 몇 번째 문제인지 (1부터)
    public let number: Int
    public let problem: ProblemPayload

    public init(problem: PracticeProblem, number: Int) {
        self.number = number
        self.problem = ProblemPayload(problem)
    }
}

public struct MissedPointPayload: Codable, Equatable, Sendable {
    public let chunkId: Int64
    public let fileName: String
    public let page: Int
    public let paragraphStart: Int
    public let paragraphEnd: Int
    public let quote: String

    public init(chunk: Chunk, fileName: String, quote: String) {
        chunkId = chunk.id ?? -1
        self.fileName = fileName
        page = chunk.pageIndex + 1
        paragraphStart = chunk.paragraphStart + 1
        paragraphEnd = chunk.paragraphEnd + 1
        self.quote = quote
    }
}

public struct ProblemAnsweredPayload: Codable, Equatable, Sendable {
    public let problemId: String
    public let type: String
    /// 이 문제에서 몇 번째 제출인지 (1부터)
    public let attemptNumber: Int
    /// 문제를 보여준 뒤 제출까지 걸린 시간
    public let elapsedMs: Int
    public let answer: String
    public let verdict: String
    public let score: Double
    public let feedback: String
    /// 빠진 요점 번호 (1부터, 문제의 keyPoints 순서)
    public let missedKeyPoints: [Int]
    public let missedLocations: [MissedPointPayload]
    public let gradedBy: String
    public let latencyMs: Int
    public let rawResponse: String?

    public init(problem: PracticeProblem, attempt: ProblemAttempt, attemptNumber: Int, elapsedMs: Int, missed: [MissedPointPayload]) {
        problemId = problem.id
        type = problem.type.rawValue
        self.attemptNumber = attemptNumber
        self.elapsedMs = elapsedMs
        answer = attempt.answer
        verdict = attempt.verdict.rawValue
        score = attempt.score
        feedback = attempt.feedback
        missedKeyPoints = attempt.missedKeyPoints.map { $0 + 1 }
        missedLocations = missed
        gradedBy = attempt.gradedBy
        latencyMs = attempt.latencyMs
        rawResponse = attempt.rawResponse
    }
}

public struct ProblemSkippedPayload: Codable, Equatable, Sendable {
    public let problemId: String
    /// 넘기기 전까지 제출한 횟수
    public let attempts: Int
    public let elapsedMs: Int

    public init(problemId: String, attempts: Int, elapsedMs: Int) {
        self.problemId = problemId
        self.attempts = attempts
        self.elapsedMs = elapsedMs
    }
}
