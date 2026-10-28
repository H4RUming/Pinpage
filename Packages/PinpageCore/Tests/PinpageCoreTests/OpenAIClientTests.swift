import Foundation
import Testing
@testable import PinpageCore

/// 네트워크 없이 서버 응답을 흉내 내는 URLProtocol.
/// 핸들러가 전역 하나라서 이 파일의 테스트는 `.serialized`로 순서대로 돌린다.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case http(status: Int, body: Data)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock {
            self.handler = handler
            captured = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        // URLSession은 httpBody를 httpBodyStream으로 바꿔 넘긴다.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Data(reading: stream)
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.captured.append(request)
            return Self.handler?(request)
        } ?? .failure(URLError(.unknown))

        switch reply {
        case .http(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}

/// 재시도 대기 시간을 실제로 기다리지 않고 기록만 한다.
private actor SleepRecorder {
    var delays: [Duration] = []
    func add(_ d: Duration) { delays.append(d) }
}

@Suite("OpenAI 호환 클라이언트", .serialized)
struct OpenAIClientTests {
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func client(
        _ url: String = "gpu-server:8000",
        apiKey: String = "",
        maxRetries: Int = 2,
        recorder: InMemoryLLMCallRecorder? = nil,
        sleeps: SleepRecorder? = nil
    ) throws -> OpenAIClient {
        OpenAIClient(
            endpoint: try APIEndpoint(baseURL: url, apiKey: apiKey),
            timeoutSeconds: 10,
            retryPolicy: RetryPolicy(maxRetries: maxRetries),
            session: session,
            recorder: recorder,
            sleep: { delay in await sleeps?.add(delay) }
        )
    }

    // MARK: 모델 목록

    @Test("모델 목록을 읽어 이름순으로 정렬하고 중복을 없앤다")
    func listModels() async throws {
        StubURLProtocol.install { _ in
            .http(status: 200, body: self.json(["object": "list", "data": [["id": "qwen3-8b", "object": "model"], ["id": "bge-m3"], ["id": "qwen3-8b"]]]))
        }
        let models = try await client().listModels()
        #expect(models == ["bge-m3", "qwen3-8b"])

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "http://gpu-server:8000/v1/models")
        #expect(request.httpMethod == "GET")
    }

    @Test("모델이 하나도 없으면 알려준다")
    func emptyModels() async throws {
        StubURLProtocol.install { _ in .http(status: 200, body: self.json(["data": []])) }
        let error = await #expect(throws: LLMRequestError.self) { try await client().listModels() }
        #expect(error?.kind == .emptyModelList)
    }

    @Test("OpenAI 형식이 아닌 응답(웹 페이지 등)")
    func invalidResponse() async throws {
        StubURLProtocol.install { _ in .http(status: 200, body: Data("<!DOCTYPE html><title>ComfyUI</title>".utf8)) }
        let error = await #expect(throws: LLMRequestError.self) { try await client().listModels() }
        #expect(error?.kind == .invalidResponse)
        #expect(error?.attempts == 1)
    }

    @Test("다른 서비스의 404는 '호환 API 없음'")
    func endpointNotFound() async throws {
        StubURLProtocol.install { _ in .http(status: 404, body: Data("404: Not Found".utf8)) }
        let error = await #expect(throws: LLMRequestError.self) { try await client("gpu-server:3000").listModels() }
        #expect(error?.kind == .endpointNotFound)
        #expect(error?.hostKind == .shortName)
    }

    // MARK: API 키 헤더

    @Test("키가 없으면 Authorization 헤더를 보내지 않는다", arguments: [
        "gpu-server:8000", "100.100.10.20:8000", "gpu-server.example-tailnet.ts.net:8000",
        "192.168.0.10:8000", "localhost:8000", "https://api.example.com",
    ])
    func noKeyNoHeader(url: String) async throws {
        StubURLProtocol.install { _ in .http(status: 200, body: self.json(["data": [["id": "m"]]])) }
        _ = try await client(url, apiKey: "").listModels()
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("키가 있으면 Bearer 헤더로 보낸다")
    func bearerHeader() async throws {
        StubURLProtocol.install { _ in .http(status: 200, body: self.json(["data": [["id": "m"]]])) }
        _ = try await client(apiKey: "sk-test").listModels()
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test("키 없이 인증이 필요한 서버에 접속하면 키를 입력하라고 안내한다")
    func unauthorizedWithoutKey() async throws {
        StubURLProtocol.install { _ in .http(status: 401, body: self.json(["error": ["message": "Unauthorized"]])) }
        let error = await #expect(throws: LLMRequestError.self) { try await client().listModels() }
        #expect(error?.kind == .unauthorized(hasKey: false))
        #expect(StubURLProtocol.requests.count == 1)  // 인증 오류는 재시도하지 않는다
    }

    // MARK: 연결 테스트

    @Test("채팅 연결 테스트는 1토큰 요청을 보낸다")
    func chatTest() async throws {
        StubURLProtocol.install { _ in
            .http(status: 200, body: self.json(["choices": [["message": ["role": "assistant", "content": "p"]]]]))
        }
        let result = try await client().testChat(model: "qwen3-8b")
        #expect(result.attempts == 1)
        #expect(result.latencyMs >= 0)
        #expect(result.embeddingDimension == nil)

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "http://gpu-server:8000/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "qwen3-8b")
        #expect(body["max_tokens"] as? Int == 1)
    }

    @Test("임베딩 연결 테스트는 벡터 차원을 알려준다")
    func embeddingTest() async throws {
        StubURLProtocol.install { _ in
            .http(status: 200, body: self.json(["data": [["embedding": Array(repeating: 0.1, count: 1024), "index": 0]]]))
        }
        let result = try await client().testEmbedding(model: "bge-m3")
        #expect(result.embeddingDimension == 1024)
        #expect(StubURLProtocol.requests.first?.url?.path == "/v1/embeddings")
    }

    @Test("모델을 고르지 않으면 요청하지 않는다")
    func modelNotSelected() async throws {
        StubURLProtocol.install { _ in .http(status: 200, body: Data()) }
        let error = await #expect(throws: LLMRequestError.self) { try await client().testChat(model: "") }
        #expect(error?.kind == .modelNotSelected)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test("서버에 없는 모델")
    func missingModel() async throws {
        StubURLProtocol.install { _ in
            .http(status: 404, body: self.json(["object": "error", "message": "The model `old` does not exist.", "code": 404]))
        }
        let error = await #expect(throws: LLMRequestError.self) { try await client().testChat(model: "old") }
        #expect(error?.kind == .modelNotFound(model: "old"))
    }

    // MARK: 재시도와 기록

    @Test("일시적 실패는 재시도하고 모든 시도를 기록한다")
    func retriesThenSucceeds() async throws {
        let counter = Counter()
        StubURLProtocol.install { _ in
            switch counter.next() {
            case 1: .failure(URLError(.cannotConnectToHost))
            case 2: .http(status: 503, body: self.json(["message": "loading"]))
            default: .http(status: 200, body: self.json(["data": [["id": "m"]]]))
            }
        }
        let recorder = InMemoryLLMCallRecorder()
        let sleeps = SleepRecorder()
        let models = try await client(maxRetries: 2, recorder: recorder, sleeps: sleeps).listModels()
        #expect(models == ["m"])

        let records = await recorder.records
        #expect(records.map(\.outcome) == [.retry, .retry, .success])
        #expect(records.map(\.attempt) == [1, 2, 3])
        #expect(records.map(\.errorCode) == ["cannot_connect", "server_error", nil])
        #expect(records.map(\.statusCode) == [nil, 503, 200])
        #expect(records.allSatisfy { $0.operation == .listModels && $0.latencyMs >= 0 })
        #expect(records.allSatisfy { $0.baseURL == "http://gpu-server:8000/v1" })
        #expect(await sleeps.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test("최대 재시도 후에는 실패를 기록하고 시도 횟수를 알려준다")
    func retriesExhausted() async throws {
        StubURLProtocol.install { _ in .failure(URLError(.timedOut)) }
        let recorder = InMemoryLLMCallRecorder()
        let error = await #expect(throws: LLMRequestError.self) {
            try await client("100.100.10.20:8000", maxRetries: 2, recorder: recorder, sleeps: SleepRecorder()).testChat(model: "m")
        }
        #expect(error?.kind == .timedOut)
        #expect(error?.attempts == 3)
        #expect(error?.message.contains("Tailscale") == true)
        #expect(StubURLProtocol.requests.count == 3)

        let records = await recorder.records
        #expect(records.map(\.outcome) == [.retry, .retry, .failure])
        #expect(records.allSatisfy { $0.model == "m" && $0.operation == .chat })
    }

    @Test("재시도 0회 설정이면 한 번만 보낸다")
    func noRetries() async throws {
        StubURLProtocol.install { _ in .failure(URLError(.cannotConnectToHost)) }
        let error = await #expect(throws: LLMRequestError.self) { try await client(maxRetries: 0).listModels() }
        #expect(error?.attempts == 1)
        #expect(StubURLProtocol.requests.count == 1)
    }
}

/// 핸들러 호출 횟수를 센다.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
