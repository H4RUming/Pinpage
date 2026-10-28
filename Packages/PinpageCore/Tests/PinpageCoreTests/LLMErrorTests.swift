import Foundation
import Testing
@testable import PinpageCore

@Suite("오류 분류와 한국어 메시지")
struct LLMErrorTests {
    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("URLError 분류", arguments: [
        (URLError.Code.cannotFindHost, LLMErrorKind.cannotFindHost),
        (.dnsLookupFailed, .cannotFindHost),
        (.cannotConnectToHost, .cannotConnect),
        (.timedOut, .timedOut),
        (.networkConnectionLost, .connectionLost),
        (.notConnectedToInternet, .notConnected),
        (.secureConnectionFailed, .secureConnectionFailed),
        (.cancelled, .cancelled),
    ])
    func urlErrors(code: URLError.Code, expected: LLMErrorKind) {
        #expect(LLMErrorClassifier.kind(for: URLError(code)) == expected)
    }

    @Test("로컬 네트워크 권한 거부를 따로 알아본다")
    func localNetworkDenied() {
        let error = URLError(.notConnectedToInternet, userInfo: ["_NSURLErrorNWPathKey": "unsatisfied (Local network prohibited), interface: en0"])
        #expect(LLMErrorClassifier.kind(for: error) == .localNetworkDenied)
    }

    @Test("HTTP 상태 코드 분류")
    func httpStatus() {
        let empty = Data()
        #expect(LLMErrorClassifier.kind(status: 401, body: empty, model: nil, hasKey: false) == .unauthorized(hasKey: false))
        #expect(LLMErrorClassifier.kind(status: 403, body: empty, model: nil, hasKey: true) == .unauthorized(hasKey: true))
        #expect(LLMErrorClassifier.kind(status: 429, body: empty, model: nil, hasKey: false) == .rateLimited)
        #expect(LLMErrorClassifier.kind(status: 503, body: empty, model: nil, hasKey: false) == .serverError(status: 503, detail: nil))
        // ComfyUI처럼 다른 서비스가 text/plain 404를 돌려주는 경우
        #expect(LLMErrorClassifier.kind(status: 404, body: Data("404: Not Found".utf8), model: nil, hasKey: false) == .endpointNotFound)
        // FastAPI 기본 404
        #expect(LLMErrorClassifier.kind(status: 404, body: json(["detail": "Not Found"]), model: "m", hasKey: false) == .endpointNotFound)
    }

    @Test("서버별 '모델 없음' 응답을 알아본다")
    func modelNotFound() {
        let vllm = json(["object": "error", "message": "The model `qwen` does not exist.", "type": "NotFoundError", "code": 404])
        #expect(LLMErrorClassifier.kind(status: 404, body: vllm, model: "qwen", hasKey: false) == .modelNotFound(model: "qwen"))

        let openai = json(["error": ["message": "The model `gpt-x` does not exist or you do not have access to it.", "code": "model_not_found"]])
        #expect(LLMErrorClassifier.kind(status: 404, body: openai, model: "gpt-x", hasKey: true) == .modelNotFound(model: "gpt-x"))

        let ollama = json(["error": ["message": "model \"llama\" not found, try pulling it first"]])
        #expect(LLMErrorClassifier.kind(status: 404, body: ollama, model: "llama", hasKey: false) == .modelNotFound(model: "llama"))

        let badRequest = json(["message": "model 'x' does not exist"])
        #expect(LLMErrorClassifier.kind(status: 400, body: badRequest, model: "x", hasKey: false) == .modelNotFound(model: "x"))

        let otherBadRequest = json(["message": "max_tokens must be positive"])
        #expect(LLMErrorClassifier.kind(status: 400, body: otherBadRequest, model: "x", hasKey: false) == .badRequest(status: 400, detail: "max_tokens must be positive"))
    }

    @Test("서버 메시지 추출 (JSON이 아니면 nil)")
    func serverMessage() {
        #expect(LLMErrorClassifier.serverMessage(from: json(["error": ["message": "a"]])) == "a")
        #expect(LLMErrorClassifier.serverMessage(from: json(["error": "b"])) == "b")
        #expect(LLMErrorClassifier.serverMessage(from: json(["message": "c"])) == "c")
        #expect(LLMErrorClassifier.serverMessage(from: json(["detail": "d"])) == "d")
        #expect(LLMErrorClassifier.serverMessage(from: Data("<!DOCTYPE html>".utf8)) == nil)
    }

    @Test("재시도 대상")
    func retryable() {
        #expect(LLMErrorKind.cannotConnect.isRetryable)
        #expect(LLMErrorKind.timedOut.isRetryable)
        #expect(LLMErrorKind.serverError(status: 502, detail: nil).isRetryable)
        #expect(LLMErrorKind.rateLimited.isRetryable)
        #expect(!LLMErrorKind.unauthorized(hasKey: false).isRetryable)
        #expect(!LLMErrorKind.endpointNotFound.isRetryable)
        #expect(!LLMErrorKind.modelNotFound(model: "m").isRetryable)
        #expect(!LLMErrorKind.localNetworkDenied.isRetryable)
        #expect(!LLMErrorKind.invalidResponse.isRetryable)
    }

    private func message(_ kind: LLMErrorKind, _ host: HostKind, attempts: Int = 1) -> String {
        LLMRequestError(kind: kind, hostKind: host, timeoutSeconds: 10, attempts: attempts).message
    }

    @Test("주소 종류에 맞는 안내를 덧붙인다")
    func hostHints() {
        #expect(message(.cannotFindHost, .shortName).contains("MagicDNS"))
        #expect(message(.cannotFindHost, .tailscale).contains("Tailscale"))
        #expect(!message(.cannotFindHost, .publicHost).contains("Tailscale"))
        #expect(message(.cannotConnect, .tailscale).contains("Tailscale"))
        #expect(message(.cannotConnect, .privateNetwork).contains("같은 네트워크"))
        #expect(message(.cannotConnect, .loopback).contains("이 Mac"))
        #expect(message(.timedOut, .tailscale).contains("10초"))
        #expect(message(.timedOut, .tailscale).contains("중계 서버"))
        #expect(message(.notConnected, .privateNetwork).contains("로컬 네트워크"))
        #expect(!message(.notConnected, .publicHost).contains("로컬 네트워크"))
        #expect(message(.localNetworkDenied, .privateNetwork).contains("개인정보 보호 및 보안"))
    }

    @Test("키 유무에 따라 인증 오류 문구가 다르다")
    func unauthorizedMessages() {
        #expect(message(.unauthorized(hasKey: false), .tailscale).contains("API 키가 필요"))
        #expect(message(.unauthorized(hasKey: true), .publicHost).contains("올바르지 않"))
    }

    @Test("여러 번 시도했으면 횟수를 알려준다")
    func attemptsSuffix() {
        #expect(message(.cannotConnect, .publicHost, attempts: 3).hasSuffix("(3번 시도)"))
        #expect(!message(.cannotConnect, .publicHost, attempts: 1).contains("번 시도"))
    }

    @Test("긴 서버 메시지는 잘라서 보여준다")
    func longDetail() {
        let detail = String(repeating: "가", count: 500)
        let text = message(.serverError(status: 500, detail: detail), .publicHost)
        #expect(text.count < 300)
        #expect(text.contains("…"))
    }
}

@Suite("재시도 정책")
struct RetryPolicyTests {
    @Test("최대 횟수까지만 재시도한다")
    func limits() {
        let policy = RetryPolicy(maxRetries: 2)
        #expect(policy.shouldRetry(.cannotConnect, retriesSoFar: 0))
        #expect(policy.shouldRetry(.cannotConnect, retriesSoFar: 1))
        #expect(!policy.shouldRetry(.cannotConnect, retriesSoFar: 2))
        #expect(!policy.shouldRetry(.unauthorized(hasKey: true), retriesSoFar: 0))
        #expect(!RetryPolicy(maxRetries: 0).shouldRetry(.cannotConnect, retriesSoFar: 0))
        #expect(RetryPolicy(maxRetries: -3).maxRetries == 0)
    }

    @Test("대기 시간은 두 배씩 늘고 상한을 넘지 않는다")
    func backoff() {
        let policy = RetryPolicy(maxRetries: 10)
        #expect(policy.delay(beforeRetry: 1) == .milliseconds(500))
        #expect(policy.delay(beforeRetry: 2) == .seconds(1))
        #expect(policy.delay(beforeRetry: 3) == .seconds(2))
        #expect(policy.delay(beforeRetry: 4) == .seconds(4))
        #expect(policy.delay(beforeRetry: 9) == .seconds(4))
        #expect(policy.delay(beforeRetry: 100) == .seconds(4))
    }
}
