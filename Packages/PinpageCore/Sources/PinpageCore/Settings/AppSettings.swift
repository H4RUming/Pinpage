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

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, chat, embedding, network, retrieval, learning
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

/// 임베딩 API 설정. 모델이 비어 있으면 임베딩 없이 BM25 검색만 사용한다.
public struct EmbeddingSettings: Codable, Equatable, Sendable {
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
        case useChatServer, baseURL, apiKey, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useChatServer = try c.decode(forKey: .useChatServer, default: true)
        baseURL = try c.decode(forKey: .baseURL, default: "")
        apiKey = try c.decode(forKey: .apiKey, default: "")
        model = try c.decode(forKey: .model, default: "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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
    /// 청크 최대 길이(글자 수).
    public var chunkSize = 800
    /// 이웃 청크와 겹치는 길이(글자 수).
    public var chunkOverlap = 100
    /// 검색 결과로 가져올 청크 개수.
    public var topK = 5
    /// 하이브리드 검색에서 임베딩 점수의 비중 (0이면 BM25만, 1이면 임베딩만).
    public var embeddingWeight = 0.5

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case chunkSize, chunkOverlap, topK, embeddingWeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RetrievalSettings()
        chunkSize = try c.decode(forKey: .chunkSize, default: d.chunkSize)
        chunkOverlap = try c.decode(forKey: .chunkOverlap, default: d.chunkOverlap)
        topK = try c.decode(forKey: .topK, default: d.topK)
        embeddingWeight = try c.decode(forKey: .embeddingWeight, default: d.embeddingWeight)
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
