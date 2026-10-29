import Foundation
import GRDB

/// 답안을 채점하고 기록한다.
/// - 객관식: 코드로 채점
/// - 단답형: 정답 목록과 먼저 비교하고(공백·대소문자·문장부호 무시), 맞지 않으면 AI가 같은 뜻인지 판단
/// - 서술형: AI가 채점 요점과 모범 답안을 기준으로 채점
///
/// 템플릿 자리표시자: `{{type}}`, `{{question}}`, `{{model_answer}}`, `{{accepted_answers}}`, `{{key_points}}`, `{{answer}}`
public struct ProblemGrader: Sendable {
    public let database: AppDatabase
    public let client: OpenAIClient
    public let templates: PromptTemplates
    public let request: StructuredRequest

    public init(database: AppDatabase, client: OpenAIClient, templates: PromptTemplates, request: StructuredRequest) {
        self.database = database
        self.client = client
        self.templates = templates
        self.request = request
    }

    public func grade(_ problem: PracticeProblem, answer rawAnswer: String) async throws -> ProblemAttempt {
        let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let allPoints = Array(problem.keyPoints.indices)
        var attempt: ProblemAttempt

        if answer.isEmpty {
            attempt = Self.attempt(problem, answer, .incorrect, 0, "", allPoints, by: "code")
        } else {
            switch problem.type {
            case .multipleChoice:
                let correct = Int(answer) == problem.answerIndex
                attempt = Self.attempt(problem, answer, correct ? .correct : .incorrect, correct ? 1 : 0, "",
                                       correct ? [] : allPoints, by: "code")
            case .shortAnswer where Self.matches(answer, problem.acceptedAnswers):
                attempt = Self.attempt(problem, answer, .correct, 1, "", [], by: "code")
            case .shortAnswer, .essay:
                attempt = try await gradeWithAI(problem, answer: answer)
            }
        }

        let stored = attempt
        let saved = try await database.writer.write { db -> ProblemAttempt in
            var inserted = stored
            try inserted.insert(db)
            if inserted.verdict == .correct, var problem = try PracticeProblem.fetchOne(db, key: problem.id) {
                problem.status = .solved
                try problem.update(db)
            }
            return inserted
        }
        return saved
    }

    /// 단답형 정답 비교 (공백·대소문자·문장부호·호환 문자 차이 무시).
    public static func matches(_ answer: String, _ accepted: [String]) -> Bool {
        let normalized = QuoteVerifier.normalize(answer)
        guard !normalized.isEmpty else { return false }
        return accepted.contains { QuoteVerifier.normalize($0) == normalized }
    }

    private func gradeWithAI(_ problem: PracticeProblem, answer: String) async throws -> ProblemAttempt {
        let values: [String: String] = [
            "type": problem.type.rawValue,
            "question": problem.promptText,
            "model_answer": problem.modelAnswer,
            "accepted_answers": problem.acceptedAnswers.isEmpty ? "(없음)" : problem.acceptedAnswers.joined(separator: ", "),
            "key_points": problem.keyPoints.enumerated().map { "\($0.offset + 1). \($0.element.text) (근거: \($0.element.quote))" }
                .joined(separator: "\n"),
            "answer": answer,
        ]
        let messages = [
            ChatMessage.system(try PromptTemplates.render(templates.gradeSystem, values)),
            ChatMessage.user(try PromptTemplates.render(templates.gradeUser, values)),
        ]
        let (completion, _) = try await StructuredCompletion.run(client: client, request: request, messages: messages,
                                                                 schemaName: "grade", schema: Self.schema)
        if completion.finishReason == "length" { throw AnswerEngineError.truncated }
        guard let parsed = ResponseParser.decode(RawGrade.self, from: completion.content),
              let verdict = Verdict(rawValue: parsed.verdict) else {
            throw AnswerEngineError.unparsable(raw: completion.content)
        }
        // 빠진 요점 번호는 1부터 → 0부터, 범위 밖은 버린다.
        let missed = Array(Set(parsed.missedKeyPoints.map { $0 - 1 }.filter { problem.keyPoints.indices.contains($0) })).sorted()
        var score = min(max(parsed.score, 0), 1)
        if verdict == .correct { score = max(score, 0.0) }
        if verdict == .incorrect && missed.isEmpty {
            // 틀렸는데 빠진 요점을 하나도 안 짚었으면 모든 요점을 다시 보게 한다.
            return Self.attempt(problem, answer, verdict, score, parsed.feedback, Array(problem.keyPoints.indices),
                                by: "ai", raw: completion.content, latency: completion.latencyMs)
        }
        return Self.attempt(problem, answer, verdict, score, parsed.feedback, verdict == .correct ? [] : missed,
                            by: "ai", raw: completion.content, latency: completion.latencyMs)
    }

    private static func attempt(_ problem: PracticeProblem, _ answer: String, _ verdict: Verdict, _ score: Double,
                                _ feedback: String, _ missed: [Int], by: String, raw: String? = nil, latency: Int = 0) -> ProblemAttempt {
        ProblemAttempt(id: nil, problemId: problem.id, answer: answer, verdict: verdict, score: score,
                       feedback: feedback.trimmingCharacters(in: .whitespacesAndNewlines), missedKeyPoints: missed,
                       gradedBy: by, rawResponse: raw, latencyMs: latency, createdAt: Date())
    }

    struct RawGrade: Decodable {
        let verdict: String
        let score: Double
        let feedback: String
        let missedKeyPoints: [Int]

        enum CodingKeys: String, CodingKey {
            case verdict, score, feedback
            case missedKeyPoints = "missed_key_points"
        }
    }

    static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["verdict", "score", "feedback", "missed_key_points"],
            "properties": [
                "verdict": ["type": "string", "enum": ["correct", "partial", "incorrect"]],
                "score": ["type": "number"],
                "feedback": ["type": "string"],
                "missed_key_points": ["type": "array", "items": ["type": "integer"]],
            ],
        ]
    }
}
