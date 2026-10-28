import Foundation

// OpenAI 호환 API 요청·응답 형식. 연결 확인에 필요한 필드만 정의한다.

struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }
    let data: [Model]
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int?
    let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]
}

struct EmbeddingsRequest: Encodable {
    let model: String
    let input: [String]
}

struct EmbeddingsResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]
        let index: Int?
    }
    let data: [Item]
}
