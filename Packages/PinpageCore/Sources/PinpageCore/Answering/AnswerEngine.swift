import Foundation

/// 검증을 통과한 근거.
public struct VerifiedCitation: Equatable, Sendable, Identifiable {
    /// 프롬프트의 근거 번호 (1부터)
    public let source: Int
    public let hit: SearchHit
    /// 자료에서 옮긴 인용. 1단계 힌트는 빈 문자열 (위치만 짚는다).
    public let quote: String

    public var id: String { "\(source)-\(quote)" }
    public var label: String { CitationLabel.text(fileName: hit.document.fileName, chunk: hit.chunk) }
}

/// 검증에서 버린 근거 (로그용).
public struct DroppedCitation: Equatable, Sendable {
    public let source: Int
    public let quote: String
    public let reason: String
}

public enum GroundedKind: Equatable, Sendable {
    case answer
    case hint(level: Int)
}

public enum GroundedStatus: String, Sendable {
    case answered
    /// 자료에서 근거를 찾지 못함. 화면에는 "자료에 없음"으로 보여준다.
    case notInMaterials = "not_in_materials"
}

/// 답변이나 힌트 한 번의 결과. 화면 표시와 이벤트 로그(M4)가 같은 값을 쓴다.
public struct GroundedResult: Sendable {
    public let kind: GroundedKind
    public let question: String
    public let problem: String?
    /// 검색 질의와 결과 (프롬프트에 넣은 순서 = 근거 번호 순서)
    public let searchQuery: String
    public let hits: [SearchHit]
    public let usedEmbedding: Bool
    public let status: GroundedStatus
    /// 화면에 보여줄 본문. "자료에 없음"이거나 1단계 힌트면 비어 있다.
    public let text: String
    public let citations: [VerifiedCitation]
    public let dropped: [DroppedCitation]
    /// "자료에 없음"인 이유 (검색 결과 없음, 모델 판단, 근거 확인 실패)
    public let notInMaterialsReason: String?
    /// LLM 원래 응답과 추론 (로그용, 화면에 보여주지 않는다)
    public let rawResponse: String?
    public let reasoning: String?
    public let usedJSONSchema: Bool
    public let latencyMs: Int
    public let attempts: Int
    public let model: String
    public let templateFingerprint: String
    public let startedAt: Date
}

public enum AnswerEngineError: Error, LocalizedError {
    case unparsable(raw: String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .unparsable: "모델의 답변 형식을 해석할 수 없습니다. 다시 시도하세요."
        case .truncated: "답변이 최대 길이에서 잘렸습니다. 설정에서 최대 답변 토큰을 늘리세요."
        }
    }
}

/// 자료를 검색해 근거를 붙인 답변과 단계별 힌트를 만든다.
///
/// 근거 검증은 엄격하다: 인용이 해당 청크에서 확인되지 않으면 버리고,
/// 남는 근거가 없으면 답을 보여주지 않고 "자료에 없음"으로 처리한다.
public struct AnswerEngine: Sendable {
    public struct Configuration: Sendable {
        public var model: String
        public var temperature: Double
        public var maxTokens: Int
        public var enforceJSONSchema: Bool
        /// 서버별 추가 요청 파라미터 (JSON 객체)
        public var extraBody: SendableJSON
        public var topK: Int
        public var embeddingWeight: Double

        public init(model: String, temperature: Double, maxTokens: Int, enforceJSONSchema: Bool,
                    extraBody: [String: Any], topK: Int, embeddingWeight: Double) {
            self.model = model
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.enforceJSONSchema = enforceJSONSchema
            self.extraBody = SendableJSON(extraBody)
            self.topK = topK
            self.embeddingWeight = embeddingWeight
        }

        public init(settings: AppSettings) {
            self.init(
                model: settings.chat.model,
                temperature: settings.generation.temperature,
                maxTokens: settings.generation.maxTokens,
                enforceJSONSchema: settings.generation.enforceJSONSchema,
                extraBody: settings.generation.extraBody ?? [:],
                topK: settings.retrieval.topK,
                embeddingWeight: settings.retrieval.embeddingWeight
            )
        }
    }

    public let search: SearchService
    public let client: OpenAIClient
    public let templates: PromptTemplates
    public let configuration: Configuration
    public let embedder: (any Embedder)?
    public let embeddingPrompts: EmbeddingPrompts?

    public init(search: SearchService, client: OpenAIClient, templates: PromptTemplates, configuration: Configuration,
                embedder: (any Embedder)?, embeddingPrompts: EmbeddingPrompts?) {
        self.search = search
        self.client = client
        self.templates = templates
        self.configuration = configuration
        self.embedder = embedder
        self.embeddingPrompts = embeddingPrompts
    }

    public var hintLevelCount: Int { templates.hints.count }

    // MARK: - 자유 질문

    public func answer(question: String, problem: String?, setId: String) async throws -> GroundedResult {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = Self.clean(problem)
        let query = [problem, question].compactMap { $0 }.joined(separator: "\n")
        return try await run(kind: .answer, question: question, problem: problem, query: query, setId: setId,
                             system: templates.answerSystem, user: templates.answerUser, level: nil)
    }

    // MARK: - 단계별 힌트

    /// - Parameter level: 1부터 `hintLevelCount`까지. 1단계는 위치만, 그 뒤는 템플릿대로 (설명, 정답과 풀이).
    public func hint(level: Int, problem: String, question: String?, setId: String) async throws -> GroundedResult {
        precondition((1...hintLevelCount).contains(level))
        let problem = Self.clean(problem) ?? ""
        let question = Self.clean(question)
        let query = [problem, question].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return try await run(kind: .hint(level: level), question: question ?? "", problem: problem, query: query, setId: setId,
                             system: templates.hintSystem, user: templates.hints[level - 1], level: level)
    }

    // MARK: - 공통

    private func run(kind: GroundedKind, question: String, problem: String?, query: String, setId: String,
                     system: String, user: String, level: Int?) async throws -> GroundedResult {
        let startedAt = Date()
        let found = try await search.search(setId: setId, query: query, topK: configuration.topK, embedder: embedder,
                                            prompts: embeddingPrompts, embeddingWeight: configuration.embeddingWeight)
        func result(status: GroundedStatus, text: String = "", citations: [VerifiedCitation] = [], dropped: [DroppedCitation] = [],
                    reason: String? = nil, completion: ChatCompletion? = nil, usedSchema: Bool = false) -> GroundedResult {
            GroundedResult(kind: kind, question: question, problem: problem, searchQuery: query, hits: found.hits,
                           usedEmbedding: found.usedEmbedding, status: status, text: text, citations: citations,
                           dropped: dropped, notInMaterialsReason: reason, rawResponse: completion?.content,
                           reasoning: completion?.reasoning, usedJSONSchema: usedSchema,
                           latencyMs: completion?.latencyMs ?? 0, attempts: completion?.attempts ?? 0,
                           model: configuration.model, templateFingerprint: templates.fingerprint, startedAt: startedAt)
        }

        // 검색 결과가 없으면 LLM에 묻지 않는다.
        guard !found.hits.isEmpty else {
            return result(status: .notInMaterials, reason: "검색된 자료 없음")
        }

        let values = [
            "sources": SourceBlock.render(found.hits),
            "question": question.isEmpty ? "(없음)" : question,
            "problem": (problem?.isEmpty ?? true) ? "(없음)" : problem!,
            "level": level.map(String.init) ?? "",
        ]
        let messages = [
            ChatMessage.system(try PromptTemplates.render(system, values)),
            ChatMessage.user(try PromptTemplates.render(user, values)),
        ]
        let isLocations = level == 1
        let schema = isLocations ? ResponseSchema.locations : ResponseSchema.grounded
        let (completion, usedSchema) = try await complete(messages: messages, schema: schema)
        if completion.finishReason == "length" { throw AnswerEngineError.truncated }

        if isLocations {
            guard let parsed = ResponseParser.decode(RawLocationsResponse.self, from: completion.content) else {
                throw AnswerEngineError.unparsable(raw: completion.content)
            }
            var citations: [VerifiedCitation] = []
            var dropped: [DroppedCitation] = []
            for source in parsed.sources ?? [] {
                guard found.hits.indices.contains(source - 1) else {
                    dropped.append(DroppedCitation(source: source, quote: "", reason: "없는 근거 번호"))
                    continue
                }
                if !citations.contains(where: { $0.source == source }) {
                    citations.append(VerifiedCitation(source: source, hit: found.hits[source - 1], quote: ""))
                }
            }
            if parsed.status == GroundedStatus.notInMaterials.rawValue || citations.isEmpty {
                return result(status: .notInMaterials, dropped: dropped,
                              reason: citations.isEmpty && parsed.status != "not_in_materials" ? "근거 확인 실패" : "모델 판단",
                              completion: completion, usedSchema: usedSchema)
            }
            return result(status: .answered, citations: citations, dropped: dropped, completion: completion, usedSchema: usedSchema)
        }

        guard let parsed = ResponseParser.decode(RawGroundedResponse.self, from: completion.content) else {
            throw AnswerEngineError.unparsable(raw: completion.content)
        }
        let (citations, dropped) = Self.verify(parsed.citations ?? [], hits: found.hits)
        if parsed.status == GroundedStatus.notInMaterials.rawValue {
            return result(status: .notInMaterials, dropped: dropped, reason: "모델 판단", completion: completion, usedSchema: usedSchema)
        }
        guard !citations.isEmpty else {
            return result(status: .notInMaterials, dropped: dropped, reason: "근거 확인 실패", completion: completion, usedSchema: usedSchema)
        }
        return result(status: .answered, text: (parsed.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                      citations: citations, dropped: dropped, completion: completion, usedSchema: usedSchema)
    }

    /// JSON 스키마로 요청하고, 서버가 스키마를 거부하면(400대) 한 번만 스키마 없이 다시 보낸다.
    private func complete(messages: [ChatMessage], schema: [String: Any]) async throws -> (ChatCompletion, Bool) {
        let extra = configuration.extraBody.value as? [String: Any] ?? [:]
        if configuration.enforceJSONSchema {
            do {
                let completion = try await client.chatCompletion(
                    model: configuration.model, messages: messages, temperature: configuration.temperature,
                    maxTokens: configuration.maxTokens, jsonSchema: ("grounded_answer", schema), extraBody: extra)
                return (completion, true)
            } catch let error as LLMRequestError {
                guard case .badRequest = error.kind else { throw error }
            }
        }
        let completion = try await client.chatCompletion(
            model: configuration.model, messages: messages, temperature: configuration.temperature,
            maxTokens: configuration.maxTokens, jsonSchema: nil, extraBody: extra)
        return (completion, false)
    }

    static func verify(_ raw: [RawGroundedResponse.Citation], hits: [SearchHit]) -> ([VerifiedCitation], [DroppedCitation]) {
        var verified: [VerifiedCitation] = []
        var dropped: [DroppedCitation] = []
        for citation in raw {
            let quote = (citation.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard hits.indices.contains(citation.source - 1) else {
                dropped.append(DroppedCitation(source: citation.source, quote: quote, reason: "없는 근거 번호"))
                continue
            }
            let hit = hits[citation.source - 1]
            guard QuoteVerifier.verify(quote: quote, in: hit.chunk.text) else {
                dropped.append(DroppedCitation(source: citation.source, quote: quote, reason: "인용이 자료에 없음"))
                continue
            }
            if !verified.contains(where: { $0.source == citation.source && $0.quote == quote }) {
                verified.append(VerifiedCitation(source: citation.source, hit: hit, quote: quote))
            }
        }
        return (verified, dropped)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// 설정의 추가 요청 파라미터(JSON 값)를 동시성 경계 너머로 넘기기 위한 상자.
/// JSONSerialization이 만든 값(문자열, 숫자, 배열, 사전)만 담으므로 읽기 전용으로 안전하다.
public struct SendableJSON: @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }
}
