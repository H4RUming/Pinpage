import Foundation

/// 이 Mac에 설정을 저장하고 불러온다.
/// 파일: `~/Library/Application Support/Pinpage/settings.json` (API 키 포함, 권한 600)
public struct SettingsRepository: Sendable {
    public struct LoadResult: Sendable {
        public let settings: AppSettings
        /// 사용자에게 알려야 할 문제 (파일 손상 등). 없으면 nil.
        public let warning: String?
    }

    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "settings.json")
    }

    /// 앱 데이터 폴더. 이후 마일스톤의 DB와 자료도 이 폴더에 둔다.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Pinpage", directoryHint: .isDirectory)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadResult(settings: AppSettings(), warning: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            return LoadResult(settings: settings, warning: nil)
        } catch {
            // 읽을 수 없는 파일은 지우지 않고 옆에 보관한 뒤 기본값으로 시작한다.
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "settings.corrupt-\(Self.timestamp()).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return LoadResult(
                settings: AppSettings(),
                warning: "설정 파일을 읽을 수 없어 기본값으로 시작합니다. 기존 파일은 \(backup.lastPathComponent)로 보관했습니다."
            )
        }
    }

    public func save(_ settings: AppSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
