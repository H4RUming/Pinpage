import Foundation

/// 서버 주소의 종류. 연결 실패 시 원인에 맞는 안내 문구를 고르는 데 쓴다.
/// API 키 사용 여부와는 관계없다 (키는 입력란이 비었는지로만 정한다).
public enum HostKind: Equatable, Sendable {
    /// 이 Mac (localhost, 127.x, ::1)
    case loopback
    /// 같은 네트워크 (10.x, 172.16~31.x, 192.168.x, 169.254.x, *.local)
    case privateNetwork
    /// Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48, *.ts.net)
    case tailscale
    /// 점 없는 짧은 이름 (Tailscale MagicDNS 이름 또는 사내 DNS 이름)
    case shortName
    /// 그 밖의 외부 서버
    case publicHost

    public var label: String {
        switch self {
        case .loopback: "이 Mac"
        case .privateNetwork: "로컬 네트워크"
        case .tailscale: "Tailscale"
        case .shortName: "짧은 이름 (MagicDNS 등)"
        case .publicHost: "외부 서버"
        }
    }

    /// macOS 로컬 네트워크 권한의 영향을 받을 수 있는 주소인지.
    var mayNeedLocalNetworkPermission: Bool {
        switch self {
        case .privateNetwork, .tailscale, .shortName: true
        case .loopback, .publicHost: false
        }
    }

    public static func classify(host rawHost: String) -> HostKind {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }

        if let octets = ipv4Octets(host) {
            return classifyIPv4(octets)
        }
        if host.contains(":") {
            return classifyIPv6(host)
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .loopback
        }
        if host.hasSuffix(".ts.net") {
            return .tailscale
        }
        if host.hasSuffix(".local") {
            return .privateNetwork
        }
        if !host.contains(".") {
            return .shortName
        }
        return .publicHost
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    private static func classifyIPv4(_ o: [UInt8]) -> HostKind {
        switch (o[0], o[1]) {
        case (127, _): .loopback
        case (10, _), (192, 168), (169, 254): .privateNetwork
        case (172, 16...31): .privateNetwork
        case (100, 64...127): .tailscale  // 100.64.0.0/10 (CGNAT, Tailscale이 사용)
        default: .publicHost
        }
    }

    private static func classifyIPv6(_ host: String) -> HostKind {
        if host == "::1" { return .loopback }
        if host.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return .privateNetwork }
        return .publicHost
    }
}
