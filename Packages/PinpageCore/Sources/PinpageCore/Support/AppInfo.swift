import Foundation

/// 앱 버전 정보. 설정 파일과 로그 내보내기에 기록한다.
public struct AppInfo: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public static func from(bundle: Bundle) -> AppInfo {
        let info = bundle.infoDictionary ?? [:]
        return AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            build: info["CFBundleVersion"] as? String ?? "0"
        )
    }

    /// 예: "0.1.0 (1)"
    public var displayVersion: String { "\(version) (\(build))" }
}
