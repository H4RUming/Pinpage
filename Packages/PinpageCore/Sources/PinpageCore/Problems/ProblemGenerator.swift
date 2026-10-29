import Foundation
import GRDB

public enum ProblemGenerationError: Error, LocalizedError {
    case noMaterials
    case noValidProblem(failures: [ProblemGenerationFailure])

    public var errorDescription: String? {
        switch self {
        case .noMaterials: "문제를 만들 자료가 없습니다. 학습 세트에 PDF를 넣고 색인하세요."
        case .noValidProblem: "자료에서 근거가 확인되는 문제를 만들지 못했습니다. 다시 시도하세요."
        }
    }
}

/// 문제를 만들다 버린 경우 (로그용).
public struct ProblemGenerationFailure: Codable, Equatable, Sendable {
    public let chunkId: Int64
    public let type: String
    public let reason: String
    public let rawResponse: String?
}

/// 학습 세트의 자료로 연습 문제를 만든다.
///
/// 어느 부분에서 문제를 낼지:
/// 1. 채점에서 빠진 요점이 나온 부분 (그 뒤로 다시 묻지 않았으면) — 약한 부분을 다른 방식으로 다시 묻는다.
///    같은 부분만 반복하지 않도록 한 부분에서는 `maximumAsksPerChunk`번까지만 낸다.
/// 2. 아직 문제를 낸 적 없는 부분
/// 3. 문제를 가장 적게 낸 부분
/// 같은 순위 안에서는 무작위로 고른다. 참가자마다 문제가 달라도 되며, 실제로 낸 문제는 모두 기록한다.
///
/// 객관식은 만든 뒤 같은 모델에게 자료만 주고 temperature 0으로 직접 풀게 해서,
/// 정답 번호와 다르게 풀거나 풀 수 없다고 하면 버린다 (정답 번호 자체가 틀린 문제를 걸러낸다).
///
/// 템플릿 자리표시자: `{{sources}}`, `{{type}}`, `{{difficulty}}`, `{{avoid}}`, 검증용 `{{question}}`, `{{choices}}`
public struct ProblemGenerator: Sendable {
    public static let minimumChunkLength = 60
    public static let maximumTries = 3
    public static let maximumAsksPerChunk = 3

    public let database: AppDatabase
    public let client: OpenAIClient
    public let templates: PromptTemplates
    public let request: StructuredRequest
    private let random: @Sendable (Int) -> Int

    public init(database: AppDatabase, client: OpenAIClient, templates: PromptTemplates, request: StructuredRequest,
                random: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) }) {
        self.database = database
        self.client = client
        self.templates = templates
        self.request = request
        self.random = random
    }

    public struct Output: Sendable {
        public let problem: PracticeProblem
        /// 버리고 다시 만든 시도들
        public let failures: [ProblemGenerationFailure]
    }

    public func generate(setId: String, types: [ProblemType], difficulty: Int) async throws -> Output {
        let types = types.isEmpty ? ProblemType.allCases : types
        var excluded = Set<Int64>()
        var failures: [ProblemGenerationFailure] = []

        for _ in 0..<Self.maximumTries {
            guard let target = try pickTarget(setId: setId, excluding: excluded) else {
                if failures.isEmpty { throw ProblemGenerationError.noMaterials }
                break
            }
            excluded.insert(target.chunk.id ?? -1)
            let type = types[random(types.count)]
            do {
                let problem = try await makeProblem(setId: setId, target: target, type: type, difficulty: difficulty)
                try await database.writer.write { db in try problem.insert(db) }
                return Output(problem: problem, failures: failures)
            } catch let failure as Failure {
                failures.append(ProblemGenerationFailure(chunkId: target.chunk.id ?? -1, type: type.rawValue,
                                                         reason: failure.reason, rawResponse: failure.raw))
            }
        }
        throw ProblemGenerationError.noValidProblem(failures: failures)
    }

    // MARK: - 출제 위치 고르기

    struct Target {
        let chunk: Chunk
        /// 문맥으로 함께 주는 바로 다음 청크
        let neighbor: Chunk?
        let documents: [String: Document]
        /// 같은 부분에서 냈던 문제 (반복을 피하도록 알려준다)
        let previousQuestions: [String]
    }

    func pickTarget(setId: String, excluding: Set<Int64>) throws -> Target? {
        try database.writer.read { db in
            let documents = try Document
                .filter(Column("setId") == setId && Column("status") == DocumentStatus.indexed.rawValue)
                .fetchAll(db)
            let chunks = try Chunk
                .filter(documents.map(\.id).contains(Column("documentId")))
                .order(Column("documentId"), Column("ordinal"))
                .fetchAll(db)
            let candidates = chunks.filter {
                ($0.text as NSString).length >= Self.minimumChunkLength && !excluding.contains($0.id ?? -1)
            }
            guard !candidates.isEmpty else { return nil }

            let problems = try PracticeProblem.filter(Column("setId") == setId).fetchAll(db)
            let attempts = try ProblemAttempt.filter(problems.map(\.id).contains(Column("problemId"))).fetchAll(db)
            let problemsById = Dictionary(uniqueKeysWithValues: problems.map { ($0.id, $0) })

            var usedCount: [Int64: Int] = [:]
            var lastAsked: [Int64: Date] = [:]
            var questions: [Int64: [String]] = [:]
            for problem in problems {
                guard let first = problem.sourceChunkIds.first else { continue }
                usedCount[first, default: 0] += 1
                lastAsked[first] = max(lastAsked[first] ?? .distantPast, problem.createdAt)
                questions[first, default: []].append(problem.question)
            }
            var lastMissed: [Int64: Date] = [:]
            for attempt in attempts where attempt.verdict != .correct {
                guard let problem = problemsById[attempt.problemId] else { continue }
                for index in attempt.missedKeyPoints where problem.keyPoints.indices.contains(index) {
                    let chunkId = problem.keyPoints[index].chunkId
                    lastMissed[chunkId] = max(lastMissed[chunkId] ?? .distantPast, attempt.createdAt)
                }
            }

            let weak = candidates
                .filter { chunk in
                    guard let id = chunk.id, let missed = lastMissed[id],
                          (usedCount[id] ?? 0) < Self.maximumAsksPerChunk else { return false }
                    return missed > (lastAsked[id] ?? .distantPast)
                }
                .sorted { (lastMissed[$0.id!] ?? .distantPast) < (lastMissed[$1.id!] ?? .distantPast) }
            let chosen: Chunk
            if let first = weak.first {
                chosen = first
            } else {
                let fewest = candidates.map { usedCount[$0.id ?? -1] ?? 0 }.min() ?? 0
                let pool = candidates.filter { (usedCount[$0.id ?? -1] ?? 0) == fewest }
                chosen = pool[random(pool.count)]
            }

            let neighbor = chunks.first {
                $0.documentId == chosen.documentId && $0.ordinal == chosen.ordinal + 1
                    && ($0.text as NSString).length >= Self.minimumChunkLength
            }
            return Target(chunk: chosen, neighbor: neighbor,
                          documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) }),
                          previousQuestions: questions[chosen.id ?? -1] ?? [])
        }
    }

    // MARK: - 문제 만들기

    private struct Failure: Error {
        let reason: String
        let raw: String?
    }

    private func makeProblem(setId: String, target: Target, type: ProblemType, difficulty: Int) async throws -> PracticeProblem {
        let sources = [target.chunk] + (target.neighbor.map { [$0] } ?? [])
        let sourceText: String = sources.enumerated().map { index, chunk -> String in
            let fileName = target.documents[chunk.documentId]?.fileName ?? ""
            return "[\(index + 1)] \(CitationLabel.text(fileName: fileName, chunk: chunk))\n\(chunk.text)"
        }.joined(separator: "\n\n")
        let values: [String: String] = [
            "sources": sourceText,
            "type": type.rawValue,
            "difficulty": String(difficulty),
            "avoid": target.previousQuestions.isEmpty ? "(없음)" : target.previousQuestions.map { "- \($0)" }.joined(separator: "\n"),
        ]
        let messages = [
            ChatMessage.system(try PromptTemplates.render(templates.problemSystem, values)),
            ChatMessage.user(try PromptTemplates.render(templates.problemUser, values)),
        ]
        let (completion, _) = try await StructuredCompletion.run(client: client, request: request, messages: messages,
                                                                 schemaName: "practice_problem", schema: Self.schema)
        let raw = completion.content
        guard completion.finishReason != "length" else { throw Failure(reason: "최대 길이에서 잘림", raw: raw) }
        guard let parsed = ResponseParser.decode(RawProblem.self, from: raw) else { throw Failure(reason: "형식 오류", raw: raw) }
        guard parsed.status == "ok" else { throw Failure(reason: "자료가 부족하다고 판단", raw: raw) }

        let question = parsed.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw Failure(reason: "빈 문제", raw: raw) }
        let choices = (parsed.choices ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let accepted = (parsed.acceptedAnswers ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let modelAnswer = (parsed.modelAnswer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var answerIndex: Int?
        switch type {
        case .multipleChoice:
            guard (3...6).contains(choices.count), Set(choices).count == choices.count else {
                throw Failure(reason: "객관식 보기는 서로 다른 3~6개여야 함", raw: raw)
            }
            guard let index = parsed.answerIndex, choices.indices.contains(index) else {
                throw Failure(reason: "객관식 정답 번호가 보기 범위 밖", raw: raw)
            }
            answerIndex = index
        case .shortAnswer:
            guard !accepted.isEmpty else { throw Failure(reason: "단답형 정답 없음", raw: raw) }
        case .essay:
            guard !modelAnswer.isEmpty else { throw Failure(reason: "서술형 모범 답안 없음", raw: raw) }
        }

        // 채점 요점은 근거 인용이 자료에서 확인된 것만 남긴다.
        var keyPoints: [KeyPoint] = []
        for point in parsed.keyPoints ?? [] {
            let text = point.point.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = (point.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, sources.indices.contains(point.source - 1) else { continue }
            let chunk = sources[point.source - 1]
            guard QuoteVerifier.verify(quote: quote, in: chunk.text), let chunkId = chunk.id else { continue }
            keyPoints.append(KeyPoint(text: text, chunkId: chunkId, quote: quote))
        }
        guard !keyPoints.isEmpty else { throw Failure(reason: "근거가 확인되는 채점 요점 없음", raw: raw) }
        if type == .multipleChoice, let answerIndex {
            try await checkMultipleChoice(sources: sourceText, question: question, choices: choices, answerIndex: answerIndex, raw: raw)
        }

        return PracticeProblem(
            id: UUID().uuidString, setId: setId, type: type, difficulty: difficulty, question: question,
            choices: type == .multipleChoice ? choices : [], answerIndex: answerIndex,
            acceptedAnswers: type == .shortAnswer ? accepted : [],
            modelAnswer: modelAnswer.isEmpty ? (type == .multipleChoice ? choices[answerIndex ?? 0] : accepted.joined(separator: ", ")) : modelAnswer,
            keyPoints: keyPoints, sourceChunkIds: sources.compactMap(\.id), status: .generated, createdAt: Date(),
            shownAt: nil, model: request.model, templateFingerprint: templates.fingerprint, rawResponse: raw,
            latencyMs: completion.latencyMs)
    }

    /// 자료만 보고 직접 풀어서 정답 번호가 맞는지 확인한다.
    private func checkMultipleChoice(sources: String, question: String, choices: [String], answerIndex: Int, raw: String) async throws {
        let values: [String: String] = [
            "sources": sources,
            "question": question,
            "choices": choices.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "\n"),
        ]
        let messages = [
            ChatMessage.system(try PromptTemplates.render(templates.problemCheckSystem, values)),
            ChatMessage.user(try PromptTemplates.render(templates.problemCheckUser, values)),
        ]
        var check = request
        check.temperature = 0
        let (completion, _) = try await StructuredCompletion.run(client: client, request: check, messages: messages,
                                                                 schemaName: "problem_check", schema: Self.checkSchema)
        guard let result = ResponseParser.decode(RawCheck.self, from: completion.content) else {
            throw Failure(reason: "정답 검증 응답 형식 오류", raw: raw)
        }
        guard result.answerable else { throw Failure(reason: "검증 풀이에서 풀 수 없다고 판단", raw: raw) }
        guard result.answer - 1 == answerIndex else {
            throw Failure(reason: "검증 풀이(\(result.answer)번)와 정답(\(answerIndex + 1)번) 불일치", raw: raw)
        }
    }

    struct RawCheck: Decodable {
        let answerable: Bool
        let answer: Int
    }

    static var checkSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["answerable", "answer"],
            "properties": ["answerable": ["type": "boolean"], "answer": ["type": "integer"]],
        ]
    }

    struct RawProblem: Decodable {
        struct Point: Decodable {
            let point: String
            let source: Int
            let quote: String?
        }
        let status: String
        let question: String
        let choices: [String]?
        let answerIndex: Int?
        let acceptedAnswers: [String]?
        let modelAnswer: String?
        let keyPoints: [Point]?

        enum CodingKeys: String, CodingKey {
            case status, question, choices
            case answerIndex = "answer_index"
            case acceptedAnswers = "accepted_answers"
            case modelAnswer = "model_answer"
            case keyPoints = "key_points"
        }
    }

    static var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["status", "question", "choices", "answer_index", "accepted_answers", "model_answer", "key_points"],
            "properties": [
                "status": ["type": "string", "enum": ["ok", "insufficient"]],
                "question": ["type": "string"],
                "choices": ["type": "array", "items": ["type": "string"]],
                "answer_index": ["type": "integer"],
                "accepted_answers": ["type": "array", "items": ["type": "string"]],
                "model_answer": ["type": "string"],
                "key_points": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["point", "source", "quote"],
                        "properties": [
                            "point": ["type": "string"], "source": ["type": "integer"], "quote": ["type": "string"],
                        ],
                    ],
                ],
            ],
        ]
    }
}
