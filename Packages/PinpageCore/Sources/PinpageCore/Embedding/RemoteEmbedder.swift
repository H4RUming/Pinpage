import Foundation

/// OpenAI 호환 `/v1/embeddings`로 임베딩을 만든다.
public struct RemoteEmbedder: Embedder {
    public let key: String
    public let client: OpenAIClient
    public let model: String
    public static let batchSize = 16

    public init(client: OpenAIClient, model: String, key: String) {
        self.client = client
        self.model = model
        self.key = key
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            vectors += try await client.embeddings(model: model, inputs: Array(texts[start..<min(start + Self.batchSize, texts.count)]))
        }
        return vectors
    }
}
