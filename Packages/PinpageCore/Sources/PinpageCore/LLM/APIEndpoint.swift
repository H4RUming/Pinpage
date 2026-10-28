import Foundation

/// OpenAI 호환 API 서버의 접속 정보.
///
/// 사용자가 입력한 주소를 정규화해서 항상 `.../v1`로 끝나는 base URL을 만든다.
/// - 스킴이 없으면 http://를 붙인다 (`gpu-server:8000` → `http://gpu-server:8000/v1`)
/// - 끝의 `/`, `/models`, `/chat/completions`, `/embeddings`는 지운다
/// - `/v1`로 끝나지 않으면 `/v1`을 붙인다
public struct APIEndpoint: Equatable, Sendable {
    public let baseURL: URL
    /// nil이면 Authorization 헤더를 보내지 않는다.
    public let apiKey: String?
    public let hostKind: HostKind

    public init(baseURL raw: String, apiKey: String = "") throws(EndpointError) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }

        // "gpu-server:8000"은 URL로 읽으면 "gpu-server"가 스킴이 되므로 "://" 유무로 판단한다.
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text) else { throw .invalid }

        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(scheme) }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        var path = components.path
        path.trimTrailingSlashes()
        for suffix in ["/chat/completions", "/completions", "/embeddings", "/models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        path.trimTrailingSlashes()
        if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path

        guard let url = components.url else { throw .invalid }
        self.baseURL = url
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = key.isEmpty ? nil : key
        self.hostKind = HostKind.classify(host: host)
    }

    /// `models`, `chat/completions` 같은 하위 경로의 전체 URL.
    public func url(for path: String) -> URL {
        baseURL.appending(path: path)
    }
}

public enum EndpointError: Error, Equatable, Sendable {
    case empty
    case invalid
    case unsupportedScheme(String)
    case missingHost

    public var message: String {
        switch self {
        case .empty:
            "주소를 입력하세요."
        case .invalid:
            "주소 형식이 올바르지 않습니다. 예: http://gpu-server:8000 또는 http://192.168.0.10:8000"
        case .unsupportedScheme(let scheme):
            "'\(scheme)://' 주소는 쓸 수 없습니다. http:// 또는 https://로 시작해야 합니다."
        case .missingHost:
            "주소에 서버 이름이나 IP가 없습니다."
        }
    }
}

private extension String {
    mutating func trimTrailingSlashes() {
        while hasSuffix("/") { removeLast() }
    }
}
