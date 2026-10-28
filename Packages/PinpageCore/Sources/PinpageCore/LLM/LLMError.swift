import Foundation

/// LLM 요청 실패의 종류.
public enum LLMErrorKind: Equatable, Sendable {
    case cannotFindHost
    case cannotConnect
    case timedOut
    case connectionLost
    case notConnected
    case localNetworkDenied
    case secureConnectionFailed
    case unauthorized(hasKey: Bool)
    /// 주소는 맞지만 OpenAI 호환 API 경로가 없음 (포트가 다른 서비스인 경우 등)
    case endpointNotFound
    /// LLM 서버는 맞지만 임베딩 API(/v1/embeddings)가 없음 (생성 모델만 띄운 vLLM 등)
    case embeddingsNotSupported
    case modelNotFound(model: String)
    case modelNotSelected
    case rateLimited
    case badRequest(status: Int, detail: String?)
    case serverError(status: Int, detail: String?)
    /// 응답이 OpenAI 호환 JSON이 아님
    case invalidResponse
    case emptyModelList
    case cancelled
    case other(String)

    /// 다시 보내면 성공할 수 있는 일시적인 실패인지.
    public var isRetryable: Bool {
        switch self {
        case .cannotFindHost, .cannotConnect, .timedOut, .connectionLost, .notConnected, .rateLimited, .serverError:
            true
        default:
            false
        }
    }

    /// 로그에 남기는 고정 코드. 화면 문구가 바뀌어도 바뀌지 않는다.
    public var code: String {
        switch self {
        case .cannotFindHost: "cannot_find_host"
        case .cannotConnect: "cannot_connect"
        case .timedOut: "timed_out"
        case .connectionLost: "connection_lost"
        case .notConnected: "not_connected"
        case .localNetworkDenied: "local_network_denied"
        case .secureConnectionFailed: "secure_connection_failed"
        case .unauthorized: "unauthorized"
        case .endpointNotFound: "endpoint_not_found"
        case .embeddingsNotSupported: "embeddings_not_supported"
        case .modelNotFound: "model_not_found"
        case .modelNotSelected: "model_not_selected"
        case .rateLimited: "rate_limited"
        case .badRequest: "bad_request"
        case .serverError: "server_error"
        case .invalidResponse: "invalid_response"
        case .emptyModelList: "empty_model_list"
        case .cancelled: "cancelled"
        case .other: "other"
        }
    }
}

/// 사용자에게 보여줄 수 있는 LLM 요청 실패.
public struct LLMRequestError: Error, LocalizedError, Equatable, Sendable {
    public let kind: LLMErrorKind
    public let hostKind: HostKind
    public let timeoutSeconds: Int
    /// 재시도를 포함한 총 시도 횟수.
    public let attempts: Int

    public init(kind: LLMErrorKind, hostKind: HostKind, timeoutSeconds: Int, attempts: Int) {
        self.kind = kind
        self.hostKind = hostKind
        self.timeoutSeconds = timeoutSeconds
        self.attempts = attempts
    }

    public var errorDescription: String? { message }

    /// 한국어 안내 문구.
    public var message: String {
        var text = baseMessage
        if let hint = hostHint { text += " " + hint }
        if attempts > 1 { text += " (\(attempts)번 시도)" }
        return text
    }

    private static let localNetworkSettingsPath = "시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 Pinpage를 켜주세요."

    private var baseMessage: String {
        switch kind {
        case .cannotFindHost:
            "서버 주소를 찾을 수 없습니다. 주소에 오타가 없는지 확인하세요."
        case .cannotConnect:
            "서버에 연결할 수 없습니다. 주소와 포트 번호, 서버가 실행 중인지 확인하세요."
        case .timedOut:
            "응답 시간이 초과되었습니다(\(timeoutSeconds)초). 서버가 바쁘거나 네트워크가 느릴 수 있습니다. 설정에서 시간 제한을 늘릴 수 있습니다."
        case .connectionLost:
            "요청 도중 서버 연결이 끊어졌습니다."
        case .notConnected:
            if hostKind.mayNeedLocalNetworkPermission {
                "네트워크에 연결할 수 없습니다. Wi-Fi 연결을 확인하세요. 로컬 네트워크 권한이 꺼져 있어도 이 오류가 날 수 있습니다: " + Self.localNetworkSettingsPath
            } else {
                "네트워크에 연결되어 있지 않습니다. Wi-Fi 연결을 확인하세요."
            }
        case .localNetworkDenied:
            "로컬 네트워크 접근이 거부되었습니다. " + Self.localNetworkSettingsPath
        case .secureConnectionFailed:
            "보안 연결(HTTPS)에 실패했습니다. 서버가 https를 지원하지 않으면 주소를 http://로 시작하게 입력하세요."
        case .unauthorized(let hasKey):
            hasKey
                ? "API 키가 올바르지 않거나 권한이 없습니다. 키를 다시 확인하세요."
                : "이 서버는 API 키가 필요합니다. 설정에서 API 키를 입력하세요."
        case .endpointNotFound:
            "이 주소에서 OpenAI 호환 API를 찾을 수 없습니다(404). 포트 번호가 맞는지, LLM 서버(vLLM 등)의 주소인지 확인하세요."
        case .embeddingsNotSupported:
            "이 서버는 임베딩 API(/v1/embeddings)를 제공하지 않습니다. 임베딩 서버 주소를 따로 지정하거나, 임베딩 모델을 '사용 안 함'으로 두면 키워드 검색(BM25)만 사용합니다."
        case .modelNotFound(let model):
            "서버에 '\(model)' 모델이 없습니다. [모델 불러오기]로 목록을 새로 받아 다시 선택하세요."
        case .modelNotSelected:
            "모델을 먼저 선택하세요."
        case .rateLimited:
            "요청이 너무 많아 서버가 거절했습니다(429). 잠시 후 다시 시도하세요."
        case .badRequest(let status, let detail):
            "서버가 요청을 거절했습니다(\(status))." + Self.detailSuffix(detail)
        case .serverError(let status, let detail):
            "서버 내부 오류가 발생했습니다(\(status))." + Self.detailSuffix(detail)
        case .invalidResponse:
            "서버 응답이 OpenAI 호환 형식이 아닙니다. LLM 서버가 아닌 다른 서비스(웹 페이지 등)의 주소일 수 있습니다."
        case .emptyModelList:
            "서버에 사용할 수 있는 모델이 없습니다."
        case .cancelled:
            "요청이 취소되었습니다."
        case .other(let description):
            "알 수 없는 오류가 발생했습니다: \(description)"
        }
    }

    /// 주소 종류에 따라 덧붙이는 확인 사항.
    private var hostHint: String? {
        switch (kind, hostKind) {
        case (.cannotFindHost, .shortName), (.cannotFindHost, .tailscale):
            "Tailscale(MagicDNS) 이름이라면 이 Mac에서 Tailscale이 켜져 있고 로그인돼 있는지 확인하세요. 그래도 안 되면 100.x.x.x 주소를 직접 입력해 보세요."
        case (.cannotConnect, .tailscale), (.cannotConnect, .shortName), (.connectionLost, .tailscale), (.connectionLost, .shortName):
            "Tailscale 주소라면 이 Mac과 서버 기기 모두 Tailscale에 연결돼 있는지 확인하세요."
        case (.cannotConnect, .privateNetwork):
            "서버와 같은 네트워크(Wi-Fi)에 연결돼 있는지 확인하세요."
        case (.cannotConnect, .loopback):
            "이 Mac에서 서버가 실행 중인지 확인하세요."
        case (.timedOut, .tailscale), (.timedOut, .shortName):
            "Tailscale 연결이 중계 서버를 거치면 느려질 수 있습니다."
        default:
            nil
        }
    }

    private static func detailSuffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        let trimmed = detail.count > 200 ? String(detail.prefix(200)) + "…" : detail
        return " 서버 메시지: \(trimmed)"
    }
}

// MARK: - 분류

enum LLMErrorClassifier {
    static func kind(for urlError: URLError) -> LLMErrorKind {
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .cannotFindHost
        case .cannotConnectToHost:
            return .cannotConnect
        case .timedOut:
            return .timedOut
        case .networkConnectionLost:
            return .connectionLost
        case .notConnectedToInternet:
            return isLocalNetworkProhibited(urlError) ? .localNetworkDenied : .notConnected
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed
        case .cancelled:
            return .cancelled
        default:
            return .other(urlError.localizedDescription)
        }
    }

    /// macOS 로컬 네트워크 권한이 거부되면 경로 상태에 "Local network prohibited"가 담겨 온다.
    private static func isLocalNetworkProhibited(_ error: URLError) -> Bool {
        String(describing: (error as NSError).userInfo).localizedCaseInsensitiveContains("local network prohibited")
    }

    /// HTTP 오류 상태 코드를 분류한다.
    /// - Parameter model: 요청에 쓴 모델명 (모델 목록 요청이면 nil)
    static func kind(status: Int, body: Data, model: String?, hasKey: Bool, operation: LLMOperation = .listModels) -> LLMErrorKind {
        let detail = serverMessage(from: body)
        let mentionsModel = detail?.localizedCaseInsensitiveContains("model") ?? false

        switch status {
        case 401, 403:
            return .unauthorized(hasKey: hasKey)
        case 404:
            if let model, mentionsModel { return .modelNotFound(model: model) }
            return operation == .embeddings ? .embeddingsNotSupported : .endpointNotFound
        case 400, 422:
            if let model, mentionsModel, let detail, looksLikeMissingModel(detail) {
                return .modelNotFound(model: model)
            }
            return .badRequest(status: status, detail: detail)
        case 408:
            return .timedOut
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError(status: status, detail: detail)
        default:
            return .badRequest(status: status, detail: detail)
        }
    }

    private static func looksLikeMissingModel(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("not exist") || lower.contains("not found") || lower.contains("does not")
    }

    /// OpenAI(`error.message`), vLLM(`message`), FastAPI(`detail`) 형식의 오류 메시지를 꺼낸다.
    /// JSON이 아니면(HTML 등) nil.
    static func serverMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        if let detail = object["detail"] as? String { return detail }
        return nil
    }
}
