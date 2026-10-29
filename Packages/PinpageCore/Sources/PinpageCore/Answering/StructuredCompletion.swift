import Foundation

/// JSON 응답을 받는 LLM 요청 설정.
public struct StructuredRequest: Sendable {
    public var model: String
    public var temperature: Double
    public var maxTokens: Int
    public var enforceJSONSchema: Bool
    /// 서버별 추가 요청 파라미터 (JSON 객체)
    public var extraBody: SendableJSON

    public init(model: String, temperature: Double, maxTokens: Int, enforceJSONSchema: Bool, extraBody: [String: Any]) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.enforceJSONSchema = enforceJSONSchema
        self.extraBody = SendableJSON(extraBody)
    }

    /// 설정의 답변 생성 값으로 만든다. `temperature`를 주면 그 값을 쓴다 (예: 문제 생성).
    public init(settings: AppSettings, temperature: Double? = nil) {
        self.init(model: settings.chat.model,
                  temperature: temperature ?? settings.generation.temperature,
                  maxTokens: settings.generation.maxTokens,
                  enforceJSONSchema: settings.generation.enforceJSONSchema,
                  extraBody: settings.generation.extraBody ?? [:])
    }
}

enum StructuredCompletion {
    /// JSON 스키마로 요청하고, 서버가 스키마를 거부하면(400대) 한 번만 스키마 없이 다시 보낸다.
    /// - Returns: 응답과, 스키마를 실제로 썼는지
    static func run(client: OpenAIClient, request: StructuredRequest, messages: [ChatMessage],
                    schemaName: String, schema: [String: Any]) async throws -> (ChatCompletion, Bool) {
        let extra = request.extraBody.value as? [String: Any] ?? [:]
        if request.enforceJSONSchema {
            do {
                let completion = try await client.chatCompletion(
                    model: request.model, messages: messages, temperature: request.temperature,
                    maxTokens: request.maxTokens, jsonSchema: (schemaName, schema), extraBody: extra)
                return (completion, true)
            } catch let error as LLMRequestError {
                guard case .badRequest = error.kind else { throw error }
            }
        }
        let completion = try await client.chatCompletion(
            model: request.model, messages: messages, temperature: request.temperature,
            maxTokens: request.maxTokens, jsonSchema: nil, extraBody: extra)
        return (completion, false)
    }
}
