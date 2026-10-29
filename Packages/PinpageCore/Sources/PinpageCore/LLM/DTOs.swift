import Foundation

// OpenAI 호환 API 요청·응답 형식. 연결 확인에 필요한 필드만 정의한다.

struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }
    let data: [Model]
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: "system", content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: "user", content: content) }
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
            let reasoningContent: String?
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
            }
        }
        let message: Message?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
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
