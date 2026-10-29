import Foundation

/// 앱 전체 설정.
///
/// 진행자가 내보낸 설정 파일을 모든 참가자가 불러와 같은 값으로 실험하므로,
/// 필드 이름을 바꾸거나 지우지 않는다. 새 필드는 기본값과 함께 추가한다.
/// 파일에 없는 필드는 기본값으로 채워서 읽는다.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = AppSettings.currentSchemaVersion
    public var chat = EndpointSettings()
    public var embedding = EmbeddingSettings()
    public var network = NetworkSettings()
    public var retrieval = RetrievalSettings()
    public var learning = LearningSettings()
    public var generation = GenerationSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, chat, embedding, network, retrieval, learning, generation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = try c.decode(forKey: .schemaVersion, default: d.schemaVersion)
        chat = try c.decode(forKey: .chat, default: d.chat)
        embedding = try c.decode(forKey: .embedding, default: d.embedding)
        network = try c.decode(forKey: .network, default: d.network)
        retrieval = try c.decode(forKey: .retrieval, default: d.retrieval)
        learning = try c.decode(forKey: .learning, default: d.learning)
        generation = try c.decode(forKey: .generation, default: d.generation)
    }
}

/// Chat API 서버 설정.
public struct EndpointSettings: Codable, Equatable, Sendable {
    public var baseURL = ""
    /// 비어 있으면 Authorization 헤더를 보내지 않는다 (로컬, Tailscale 서버 등).
    /// 설정 내보내기 파일에는 절대 포함하지 않는다.
    public var apiKey = ""
    public var model = ""

    public init(baseURL: String = "", apiKey: String = "", model: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, apiKey, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decode(forKey: .baseURL, default: "")
        apiKey = try c.decode(forKey: .apiKey, default: "")
        model = try c.decode(forKey: .model, default: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        if !encoder.excludesSecrets {
            try c.encode(apiKey, forKey: .apiKey)
        }
        try c.encode(model, forKey: .model)
    }
}

public enum EmbeddingMode: String, Codable, CaseIterable, Sendable {
    /// 임베딩 없이 키워드 검색(BM25)만
    case off
    /// 앱 안에서 Core ML 모델로 (처음 설정할 때 내려받는다)
    case builtin
    /// OpenAI 호환 /v1/embeddings
    case remote

    public var label: String {
        switch self {
        case .off: "사용 안 함 (키워드 검색만)"
        case .builtin: "앱 내장"
        case .remote: "원격 API"
        }
    }
}

/// 임베딩 설정.
public struct EmbeddingSettings: Codable, Equatable, Sendable {
    public var mode = EmbeddingMode.off

    // 앱 내장 모델
    /// Hugging Face 저장소와 고정 버전(커밋 해시). 모든 참가자가 같은 파일을 받도록 버전을 고정한다.
    public var modelRepo = ""
    public var modelRevision = ""
    /// 저장소의 manifest.json SHA-256. 내려받기와 폴더 설치 모두 이 값으로 검증한다.
    public var modelManifestSHA256 = ""
    public var computeUnit = EmbeddingComputeUnit.gpu
    /// 벡터 차원 (768, 512, 256, 128)
    public var dimension = 768

    // 원격 API
    /// true면 Chat API의 주소와 API 키를 그대로 쓴다.
    public var useChatServer = true
    public var baseURL = ""
    public var apiKey = ""
    public var model = ""

    public init(useChatServer: Bool = true, baseURL: String = "", apiKey: String = "", model: String = "") {
        self.useChatServer = useChatServer
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case mode, modelRepo, modelRevision, modelManifestSHA256, computeUnit, dimension
        case useChatServer, baseURL, apiKey, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EmbeddingSettings()
        useChatServer = try c.decode(forKey: .useChatServer, default: true)
        baseURL = try c.decode(forKey: .baseURL, default: "")
        apiKey = try c.decode(forKey: .apiKey, default: "")
        model = try c.decode(forKey: .model, default: "")
        // mode가 없던 이전 파일: 원격 모델이 지정돼 있으면 원격, 아니면 끔
        mode = try c.decodeIfPresent(EmbeddingMode.self, forKey: .mode) ?? (model.isEmpty ? .off : .remote)
        modelRepo = try c.decode(forKey: .modelRepo, default: d.modelRepo)
        modelRevision = try c.decode(forKey: .modelRevision, default: d.modelRevision)
        modelManifestSHA256 = try c.decode(forKey: .modelManifestSHA256, default: d.modelManifestSHA256)
        computeUnit = try c.decode(forKey: .computeUnit, default: d.computeUnit)
        dimension = try c.decode(forKey: .dimension, default: d.dimension)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(modelRepo, forKey: .modelRepo)
        try c.encode(modelRevision, forKey: .modelRevision)
        try c.encode(modelManifestSHA256, forKey: .modelManifestSHA256)
        try c.encode(computeUnit, forKey: .computeUnit)
        try c.encode(dimension, forKey: .dimension)
        try c.encode(useChatServer, forKey: .useChatServer)
        try c.encode(baseURL, forKey: .baseURL)
        if !encoder.excludesSecrets {
            try c.encode(apiKey, forKey: .apiKey)
        }
        try c.encode(model, forKey: .model)
    }
}

public struct NetworkSettings: Codable, Equatable, Sendable {
    /// 모델 목록 불러오기와 연결 테스트의 시간 제한(초).
    public var testTimeoutSeconds = 10
    /// 답변 생성 요청의 시간 제한(초). 답변 생성은 오래 걸릴 수 있어 따로 둔다.
    public var requestTimeoutSeconds = 120
    /// 실패한 요청을 다시 보내는 최대 횟수 (첫 시도 제외).
    public var maxRetries = 2

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case testTimeoutSeconds, requestTimeoutSeconds, maxRetries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NetworkSettings()
        testTimeoutSeconds = try c.decode(forKey: .testTimeoutSeconds, default: d.testTimeoutSeconds)
        requestTimeoutSeconds = try c.decode(forKey: .requestTimeoutSeconds, default: d.requestTimeoutSeconds)
        maxRetries = try c.decode(forKey: .maxRetries, default: d.maxRetries)
    }
}

public struct RetrievalSettings: Codable, Equatable, Sendable {
    /// 청크 최대 길이(글자 수). 이보다 긴 문단은 잘라서 여러 청크로 만든다.
    public var chunkSize = 800
    /// 긴 문단을 자를 때 이웃 청크와 겹치는 길이(글자 수).
    public var chunkOverlap = 100
    /// 이보다 짧은 문단(제목 등)은 다음 문단과 합친다(글자 수).
    public var minChunkLength = 80
    /// 검색 결과로 가져올 청크 개수.
    public var topK = 5
    /// 하이브리드 검색에서 임베딩 점수의 비중 (0이면 BM25만, 1이면 임베딩만).
    public var embeddingWeight = 0.5
    /// 텍스트 없는 PDF 페이지를 OCR할 때 쓸 언어 (비어 있으면 자동 감지).
    public var ocrLanguages = ["ko-KR", "en-US"]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case chunkSize, chunkOverlap, minChunkLength, topK, embeddingWeight, ocrLanguages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RetrievalSettings()
        chunkSize = try c.decode(forKey: .chunkSize, default: d.chunkSize)
        chunkOverlap = try c.decode(forKey: .chunkOverlap, default: d.chunkOverlap)
        minChunkLength = try c.decode(forKey: .minChunkLength, default: d.minChunkLength)
        topK = try c.decode(forKey: .topK, default: d.topK)
        embeddingWeight = try c.decode(forKey: .embeddingWeight, default: d.embeddingWeight)
        ocrLanguages = try c.decode(forKey: .ocrLanguages, default: d.ocrLanguages)
    }
}

public struct LearningSettings: Codable, Equatable, Sendable {
    /// 퀴즈 통과 기준 (0~1, 0.8 = 80%).
    public var quizPassThreshold = 0.8
    /// 힌트 단계 수.
    public var hintLevels = 3

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case quizPassThreshold, hintLevels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LearningSettings()
        quizPassThreshold = try c.decode(forKey: .quizPassThreshold, default: d.quizPassThreshold)
        hintLevels = try c.decode(forKey: .hintLevels, default: d.hintLevels)
    }
}

/// 답변·힌트 생성 요청 값.
public struct GenerationSettings: Codable, Equatable, Sendable {
    public var temperature = 0.0
    /// 답변 최대 토큰.
    public var maxTokens = 1024
    /// JSON 스키마로 응답 형식을 강제한다 (서버가 지원하지 않으면 프롬프트로만 요구한다).
    public var enforceJSONSchema = true
    /// 서버별 추가 요청 파라미터 (JSON 객체). 예: {"chat_template_kwargs": {"enable_thinking": false}}
    public var extraBodyJSON = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case temperature, maxTokens, enforceJSONSchema, extraBodyJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GenerationSettings()
        temperature = try c.decode(forKey: .temperature, default: d.temperature)
        maxTokens = try c.decode(forKey: .maxTokens, default: d.maxTokens)
        enforceJSONSchema = try c.decode(forKey: .enforceJSONSchema, default: d.enforceJSONSchema)
        extraBodyJSON = try c.decode(forKey: .extraBodyJSON, default: d.extraBodyJSON)
    }

    /// 추가 요청 파라미터. 비어 있으면 빈 객체, JSON 객체가 아니면 nil.
    public var extraBody: [String: Any]? {
        let trimmed = extraBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }
}

// MARK: - Encoding helpers

extension CodingUserInfoKey {
    /// true로 설정하면 API 키 같은 비밀 값을 인코딩하지 않는다 (설정 내보내기용).
    public static let excludeSecrets = CodingUserInfoKey(rawValue: "pinpage.excludeSecrets")!
}

extension Encoder {
    var excludesSecrets: Bool {
        userInfo[.excludeSecrets] as? Bool ?? false
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(forKey key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue
    }
}
