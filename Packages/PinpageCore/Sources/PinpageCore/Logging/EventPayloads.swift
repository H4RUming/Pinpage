import Foundation

// 이벤트 내용 형식. 키 이름은 내보내기 파일(M6)의 열이 되므로 바꾸지 않는다.

public struct LLMCallPayload: Codable, Equatable, Sendable {
    public let operation: String
    public let baseURL: String
    public let model: String?
    public let attempt: Int
    public let outcome: String
    public let latencyMs: Int
    public let statusCode: Int?
    public let errorCode: String?
    public let startedAt: Date

    public init(_ call: LLMCallRecord) {
        operation = call.operation.rawValue
        baseURL = call.baseURL
        model = call.model
        attempt = call.attempt
        outcome = call.outcome.rawValue
        latencyMs = call.latencyMs
        statusCode = call.statusCode
        errorCode = call.errorCode
        startedAt = call.startedAt
    }
}

public struct AppStatePayload: Codable, Equatable, Sendable {
    /// launch, quit, inactive, active, sleep, wake
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// 검색 결과 한 줄.
public struct HitPayload: Codable, Equatable, Sendable {
    public let rank: Int
    public let chunkId: Int64
    public let documentId: String
    public let fileName: String
    public let page: Int
    public let paragraphStart: Int
    public let paragraphEnd: Int
    public let source: String
    public let score: Double
    public let bm25: Double
    public let semantic: Double?

    public init(_ hit: SearchHit) {
        rank = hit.rank
        chunkId = hit.chunk.id ?? -1
        documentId = hit.document.id
        fileName = hit.document.fileName
        page = hit.chunk.pageIndex + 1
        paragraphStart = hit.chunk.paragraphStart + 1
        paragraphEnd = hit.chunk.paragraphEnd + 1
        source = hit.chunk.source.rawValue
        score = hit.score
        bm25 = hit.bm25
        semantic = hit.semantic
    }
}

public struct CitationPayload: Codable, Equatable, Sendable {
    public let source: Int
    public let chunkId: Int64
    public let fileName: String
    public let page: Int
    public let paragraphStart: Int
    public let paragraphEnd: Int
    public let quote: String

    public init(_ citation: VerifiedCitation) {
        source = citation.source
        chunkId = citation.hit.chunk.id ?? -1
        fileName = citation.hit.document.fileName
        page = citation.hit.chunk.pageIndex + 1
        paragraphStart = citation.hit.chunk.paragraphStart + 1
        paragraphEnd = citation.hit.chunk.paragraphEnd + 1
        quote = citation.quote
    }
}

public struct DroppedCitationPayload: Codable, Equatable, Sendable {
    public let source: Int
    public let quote: String
    public let reason: String

    public init(_ dropped: DroppedCitation) {
        source = dropped.source
        quote = dropped.quote
        reason = dropped.reason
    }
}

/// 질문하거나 힌트를 요청했을 때.
public struct RequestPayload: Codable, Equatable, Sendable {
    public let requestId: String
    public let setId: String
    public let problemId: String?
    /// 질문 원문 (힌트면 nil)
    public let question: String?
    /// 힌트 단계 (질문이면 nil)
    public let hintLevel: Int?

    public init(requestId: String, setId: String, problemId: String?, question: String?, hintLevel: Int?) {
        self.requestId = requestId
        self.setId = setId
        self.problemId = problemId
        self.question = question
        self.hintLevel = hintLevel
    }
}

/// 답변이나 힌트를 받았을 때. 검색 결과, 근거, LLM 원래 응답까지 모두 남긴다.
public struct GroundedPayload: Codable, Equatable, Sendable {
    public let requestId: String
    public let setId: String
    public let problemId: String?
    public let kind: String
    public let hintLevel: Int?
    public let question: String
    public let problem: String?
    public let searchQuery: String
    public let usedEmbedding: Bool
    public let embedderKey: String?
    public let hits: [HitPayload]
    public let status: String
    public let notInMaterialsReason: String?
    public let text: String
    public let citations: [CitationPayload]
    public let dropped: [DroppedCitationPayload]
    public let rawResponse: String?
    public let reasoning: String?
    public let usedJSONSchema: Bool
    public let latencyMs: Int
    public let attempts: Int
    public let model: String
    public let templateFingerprint: String
    public let startedAt: Date
    /// 실패했을 때의 오류 문구 (성공이면 nil)
    public let error: String?

    public init(requestId: String, setId: String, problemId: String?, result: GroundedResult, embedderKey: String?) {
        self.requestId = requestId
        self.setId = setId
        self.problemId = problemId
        switch result.kind {
        case .answer:
            kind = "answer"
            hintLevel = nil
        case .hint(let level):
            kind = "hint"
            hintLevel = level
        }
        question = result.question
        problem = result.problem
        searchQuery = result.searchQuery
        usedEmbedding = result.usedEmbedding
        self.embedderKey = embedderKey
        hits = result.hits.map(HitPayload.init)
        status = result.status.rawValue
        notInMaterialsReason = result.notInMaterialsReason
        text = result.text
        citations = result.citations.map(CitationPayload.init)
        dropped = result.dropped.map(DroppedCitationPayload.init)
        rawResponse = result.rawResponse
        reasoning = result.reasoning
        usedJSONSchema = result.usedJSONSchema
        latencyMs = result.latencyMs
        attempts = result.attempts
        model = result.model
        templateFingerprint = result.templateFingerprint
        startedAt = result.startedAt
        error = nil
    }

    /// 실패한 요청 (오류 문구만 남는다).
    public init(requestId: String, setId: String, problemId: String?, kind: String, hintLevel: Int?, question: String,
                problem: String?, error: String, model: String, templateFingerprint: String, startedAt: Date) {
        self.requestId = requestId
        self.setId = setId
        self.problemId = problemId
        self.kind = kind
        self.hintLevel = hintLevel
        self.question = question
        self.problem = problem
        searchQuery = ""
        usedEmbedding = false
        embedderKey = nil
        hits = []
        status = "error"
        notInMaterialsReason = nil
        text = ""
        citations = []
        dropped = []
        rawResponse = nil
        reasoning = nil
        usedJSONSchema = false
        latencyMs = 0
        attempts = 0
        self.model = model
        self.templateFingerprint = templateFingerprint
        self.startedAt = startedAt
        self.error = error
    }
}

public struct CitationOpenedPayload: Codable, Equatable, Sendable {
    public let requestId: String?
    public let problemId: String?
    public let chunkId: Int64
    public let fileName: String
    public let page: Int
    public let paragraphStart: Int
    public let paragraphEnd: Int

    public init(requestId: String?, problemId: String?, chunk: Chunk, fileName: String) {
        self.requestId = requestId
        self.problemId = problemId
        chunkId = chunk.id ?? -1
        self.fileName = fileName
        page = chunk.pageIndex + 1
        paragraphStart = chunk.paragraphStart + 1
        paragraphEnd = chunk.paragraphEnd + 1
    }
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public let context: String
    public let message: String

    public init(context: String, message: String) {
        self.context = context
        self.message = message
    }
}
