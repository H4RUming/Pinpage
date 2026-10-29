import Foundation

/// 채팅 완성 결과.
public struct ChatCompletion: Equatable, Sendable {
    public let content: String
    /// 추론 모델의 생각 과정 (서버가 따로 돌려줄 때). 화면에는 보여주지 않고 로그에만 남긴다.
    public let reasoning: String?
    public let latencyMs: Int
    public let attempts: Int
    /// "stop", "length"(최대 토큰에서 잘림) 등
    public let finishReason: String?
}

/// 연결 테스트 결과.
public struct ConnectionTestResult: Equatable, Sendable {
    /// 마지막(성공한) 시도의 응답 시간.
    public let latencyMs: Int
    /// 재시도를 포함한 총 시도 횟수.
    public let attempts: Int
    /// 임베딩 벡터 차원 (임베딩 테스트일 때만).
    public let embeddingDimension: Int?
}

/// OpenAI 호환 API(`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`) 클라이언트.
///
/// 모든 시도(재시도 포함)의 응답 시간과 결과를 `recorder`에 남긴다.
/// 실패하면 항상 `LLMRequestError`를 던진다.
public struct OpenAIClient: Sendable {
    public let endpoint: APIEndpoint
    public let timeoutSeconds: Int
    public let retryPolicy: RetryPolicy

    private let session: URLSession
    private let recorder: (any LLMCallRecorder)?
    private let sleep: @Sendable (Duration) async throws -> Void

    /// 캐시와 쿠키를 쓰지 않는 공용 세션.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(
        endpoint: APIEndpoint,
        timeoutSeconds: Int,
        retryPolicy: RetryPolicy,
        session: URLSession = OpenAIClient.defaultSession,
        recorder: (any LLMCallRecorder)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
        self.retryPolicy = retryPolicy
        self.session = session
        self.recorder = recorder
        self.sleep = sleep
    }

    // MARK: - API

    /// 서버의 모델 목록 (`GET /v1/models`), 이름순 정렬.
    public func listModels() async throws -> [String] {
        let response: ModelsResponse = try await send(.listModels, model: nil, method: "GET", path: "models", body: Optional<String>.none).value
        let ids = Array(Set(response.data.map(\.id))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !ids.isEmpty else { throw failure(.emptyModelList, attempts: 1) }
        return ids
    }

    /// 1토큰짜리 채팅 요청으로 응답 여부와 지연 시간을 확인한다.
    public func testChat(model: String) async throws -> ConnectionTestResult {
        guard !model.isEmpty else { throw failure(.modelNotSelected, attempts: 0) }
        let body = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: "ping")],
            maxTokens: 1,
            temperature: 0
        )
        let result: Sent<ChatCompletionResponse> = try await send(.chat, model: model, method: "POST", path: "chat/completions", body: body)
        return ConnectionTestResult(latencyMs: result.latencyMs, attempts: result.attempts, embeddingDimension: nil)
    }

    /// 짧은 문장을 임베딩해서 응답 여부, 지연 시간, 벡터 차원을 확인한다.
    public func testEmbedding(model: String) async throws -> ConnectionTestResult {
        guard !model.isEmpty else { throw failure(.modelNotSelected, attempts: 0) }
        let body = EmbeddingsRequest(model: model, input: ["연결 테스트"])
        let result: Sent<EmbeddingsResponse> = try await send(.embeddings, model: model, method: "POST", path: "embeddings", body: body)
        guard let dimension = result.value.data.first?.embedding.count, dimension > 0 else {
            throw failure(.invalidResponse, attempts: result.attempts)
        }
        return ConnectionTestResult(latencyMs: result.latencyMs, attempts: result.attempts, embeddingDimension: dimension)
    }

    /// 문장들의 임베딩 (`POST /v1/embeddings`). L2 정규화해서 입력 순서대로 돌려준다.
    public func embeddings(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !model.isEmpty else { throw failure(.modelNotSelected, attempts: 0) }
        guard !inputs.isEmpty else { return [] }
        let result: Sent<EmbeddingsResponse> = try await send(.embeddings, model: model, method: "POST", path: "embeddings",
                                                             body: EmbeddingsRequest(model: model, input: inputs))
        let items = result.value.data.enumerated().sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }
        guard items.count == inputs.count else { throw failure(.invalidResponse, attempts: result.attempts) }
        return items.map { VectorMath.normalized($0.element.embedding.map(Float.init)) }
    }

    /// 채팅 완성 (`POST /v1/chat/completions`).
    /// - Parameters:
    ///   - jsonSchema: 주면 `response_format: json_schema`로 응답 형식을 강제한다
    ///   - extraBody: 서버별 추가 파라미터 (예: vLLM `chat_template_kwargs`). 기본 필드를 덮어쓰지 않는다
    public func chatCompletion(
        model: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        jsonSchema: (name: String, schema: [String: Any])? = nil,
        extraBody: [String: Any] = [:]
    ) async throws -> ChatCompletion {
        guard !model.isEmpty else { throw failure(.modelNotSelected, attempts: 0) }
        var body: [String: Any] = extraBody
        body["model"] = model
        body["messages"] = messages.map { ["role": $0.role, "content": $0.content] }
        body["temperature"] = temperature
        body["max_tokens"] = maxTokens
        if let jsonSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": jsonSchema.name, "strict": true, "schema": jsonSchema.schema],
            ]
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw failure(.other("요청을 만들 수 없습니다: \(error.localizedDescription)"), attempts: 0)
        }
        let result: Sent<ChatCompletionResponse> = try await send(.chat, model: model, method: "POST", path: "chat/completions", bodyData: data)
        guard let message = result.value.choices.first?.message else {
            throw failure(.invalidResponse, attempts: result.attempts)
        }
        return ChatCompletion(content: message.content ?? "", reasoning: message.reasoningContent ?? message.reasoning,
                              latencyMs: result.latencyMs, attempts: result.attempts,
                              finishReason: result.value.choices.first?.finishReason)
    }

    // MARK: - 요청과 재시도

    struct Sent<Value> {
        let value: Value
        let attempts: Int
        let latencyMs: Int
    }

    /// HTTP 응답은 받았지만 실패로 분류된 경우.
    private struct HTTPFailure: Error {
        let kind: LLMErrorKind
        let status: Int?
    }

    func send<Response: Decodable, Body: Encodable>(
        _ operation: LLMOperation,
        model: String?,
        method: String,
        path: String,
        body: Body?
    ) async throws -> Sent<Response> {
        var data: Data?
        if let body {
            do {
                data = try JSONEncoder().encode(body)
            } catch {
                throw failure(.other("요청을 만들 수 없습니다: \(error.localizedDescription)"), attempts: 0)
            }
        }
        return try await send(operation, model: model, method: method, path: path, bodyData: data)
    }

    func send<Response: Decodable>(
        _ operation: LLMOperation,
        model: String?,
        method: String,
        path: String,
        bodyData: Data?
    ) async throws -> Sent<Response> {
        let request = makeRequest(method: method, path: path, body: bodyData)
        let clock = ContinuousClock()
        var attempt = 0

        while true {
            attempt += 1
            let startedAt = Date()
            let start = clock.now
            var status: Int?

            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPFailure(kind: .invalidResponse, status: nil)
                }
                status = http.statusCode
                guard (200..<300).contains(http.statusCode) else {
                    let kind = LLMErrorClassifier.kind(status: http.statusCode, body: data, model: model, hasKey: endpoint.apiKey != nil, operation: operation)
                    throw HTTPFailure(kind: kind, status: http.statusCode)
                }
                guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
                    throw HTTPFailure(kind: .invalidResponse, status: http.statusCode)
                }
                let latency = Self.milliseconds(clock.now - start)
                await record(operation, model: model, attempt: attempt, outcome: .success, latencyMs: latency, status: status, errorCode: nil, startedAt: startedAt)
                return Sent(value: decoded, attempts: attempt, latencyMs: latency)
            } catch {
                let latency = Self.milliseconds(clock.now - start)
                let kind = Self.classify(error)

                if retryPolicy.shouldRetry(kind, retriesSoFar: attempt - 1) {
                    await record(operation, model: model, attempt: attempt, outcome: .retry, latencyMs: latency, status: status, errorCode: kind.code, startedAt: startedAt)
                    do {
                        try await sleep(retryPolicy.delay(beforeRetry: attempt))
                    } catch {
                        throw failure(.cancelled, attempts: attempt)
                    }
                    continue
                }

                await record(operation, model: model, attempt: attempt, outcome: .failure, latencyMs: latency, status: status, errorCode: kind.code, startedAt: startedAt)
                throw failure(kind, attempts: attempt)
            }
        }
    }

    private func makeRequest(method: String, path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: endpoint.url(for: path))
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 키가 없으면 헤더를 아예 보내지 않는다. 빈 "Bearer "를 거부하는 서버가 있다.
        if let apiKey = endpoint.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private static func classify(_ error: any Error) -> LLMErrorKind {
        switch error {
        case let failure as HTTPFailure: failure.kind
        case let urlError as URLError: LLMErrorClassifier.kind(for: urlError)
        case is CancellationError: .cancelled
        default: .other(error.localizedDescription)
        }
    }

    private func failure(_ kind: LLMErrorKind, attempts: Int) -> LLMRequestError {
        LLMRequestError(kind: kind, hostKind: endpoint.hostKind, timeoutSeconds: timeoutSeconds, attempts: attempts)
    }

    private func record(
        _ operation: LLMOperation,
        model: String?,
        attempt: Int,
        outcome: LLMCallRecord.Outcome,
        latencyMs: Int,
        status: Int?,
        errorCode: String?,
        startedAt: Date
    ) async {
        guard let recorder else { return }
        await recorder.record(LLMCallRecord(
            operation: operation,
            baseURL: endpoint.baseURL.absoluteString,
            model: model,
            attempt: attempt,
            outcome: outcome,
            latencyMs: latencyMs,
            statusCode: status,
            errorCode: errorCode,
            startedAt: startedAt
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
