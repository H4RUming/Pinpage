import Foundation
import Testing
@testable import PinpageCore

@Suite("주소 정규화")
struct APIEndpointTests {
    @Test("다양한 입력이 /v1로 끝나는 같은 주소가 된다", arguments: [
        ("gpu-server:8000", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/v1", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/v1/", "http://gpu-server:8000/v1"),
        ("  http://gpu-server:8000/v1  ", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/v1/models", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/v1/chat/completions", "http://gpu-server:8000/v1"),
        ("http://gpu-server:8000/v1/embeddings", "http://gpu-server:8000/v1"),
        ("HTTP://Gpu-Server:8000", "http://Gpu-Server:8000/v1"),
        ("https://api.example.com/v1", "https://api.example.com/v1"),
        ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1"),
        ("http://proxy.local/llm", "http://proxy.local/llm/v1"),
        ("192.168.0.10:8000", "http://192.168.0.10:8000/v1"),
        ("100.100.10.20:8000", "http://100.100.10.20:8000/v1"),
        ("localhost:11434", "http://localhost:11434/v1"),
        ("http://[::1]:8000", "http://[::1]:8000/v1"),
        ("gpu-server.example-tailnet.ts.net:8000", "http://gpu-server.example-tailnet.ts.net:8000/v1"),
        ("http://gpu-server:8000/v1?x=1#frag", "http://gpu-server:8000/v1"),
    ])
    func normalizes(input: String, expected: String) throws {
        let endpoint = try APIEndpoint(baseURL: input)
        #expect(endpoint.baseURL.absoluteString == expected)
    }

    @Test("하위 경로 URL")
    func subpaths() throws {
        let endpoint = try APIEndpoint(baseURL: "gpu-server:8000")
        #expect(endpoint.url(for: "models").absoluteString == "http://gpu-server:8000/v1/models")
        #expect(endpoint.url(for: "chat/completions").absoluteString == "http://gpu-server:8000/v1/chat/completions")
    }

    @Test("잘못된 주소는 이유와 함께 거부한다")
    func rejectsInvalid() {
        #expect(throws: EndpointError.empty) { try APIEndpoint(baseURL: "   ") }
        #expect(throws: EndpointError.unsupportedScheme("ftp")) { try APIEndpoint(baseURL: "ftp://gpu-server") }
        #expect(throws: EndpointError.invalid) { try APIEndpoint(baseURL: "hai server:8000") }
        #expect(throws: EndpointError.missingHost) { try APIEndpoint(baseURL: "http://:8000") }
    }

    @Test("API 키는 앞뒤 공백을 지우고, 비어 있으면 nil")
    func apiKey() throws {
        #expect(try APIEndpoint(baseURL: "gpu-server", apiKey: "").apiKey == nil)
        #expect(try APIEndpoint(baseURL: "gpu-server", apiKey: "   ").apiKey == nil)
        #expect(try APIEndpoint(baseURL: "gpu-server", apiKey: " sk-abc ").apiKey == "sk-abc")
    }
}

@Suite("주소 종류 판정")
struct HostKindTests {
    @Test(arguments: [
        ("localhost", HostKind.loopback),
        ("api.localhost", .loopback),
        ("127.0.0.1", .loopback),
        ("::1", .loopback),
        ("[::1]", .loopback),
        ("192.168.0.10", .privateNetwork),
        ("10.0.0.5", .privateNetwork),
        ("172.16.0.1", .privateNetwork),
        ("172.31.255.255", .privateNetwork),
        ("172.32.0.1", .publicHost),
        ("169.254.10.10", .privateNetwork),
        ("my-mac.local", .privateNetwork),
        ("100.64.0.0", .tailscale),
        ("100.100.10.20", .tailscale),
        ("100.127.255.255", .tailscale),
        ("100.63.255.255", .publicHost),
        ("100.128.0.0", .publicHost),
        ("fd7a:115c:a1e0::1", .tailscale),
        ("gpu-server.example-tailnet.ts.net", .tailscale),
        ("GPU-SERVER.EXAMPLE-TAILNET.TS.NET.", .tailscale),
        ("gpu-server", .shortName),
        ("api.openai.com", .publicHost),
        ("8.8.8.8", .publicHost),
        ("999.1.1.1", .publicHost),
    ])
    func classify(host: String, expected: HostKind) {
        #expect(HostKind.classify(host: host) == expected)
    }

    @Test("정규화한 주소에서도 종류를 판정한다")
    func fromEndpoint() throws {
        #expect(try APIEndpoint(baseURL: "gpu-server:3000").hostKind == .shortName)
        #expect(try APIEndpoint(baseURL: "http://[fd7a:115c:a1e0::1]:8000").hostKind == .tailscale)
    }
}
