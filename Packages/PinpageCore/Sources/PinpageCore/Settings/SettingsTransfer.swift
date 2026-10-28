import Foundation

/// 설정 내보내기 파일 형식.
///
/// 진행자가 만든 파일 하나를 모든 참가자가 불러와 같은 모델, 같은 값으로 실험한다.
/// API 키는 절대 담지 않는다.
public struct SettingsExportFile: Codable, Sendable {
    public static let formatIdentifier = "pinpage-settings"

    public var format: String
    public var schemaVersion: Int
    public var appVersion: String
    /// ISO 8601, 시간대 포함 (예: 2026-10-28T15:30:00+09:00)
    public var exportedAt: String
    public var settings: AppSettings
}

public enum SettingsImportError: Error, LocalizedError, Equatable {
    case notJSON
    case wrongFormat
    case newerSchema(Int)
    case invalidValues([SettingsIssue])

    public var errorDescription: String? {
        switch self {
        case .notJSON:
            "JSON 파일을 읽을 수 없습니다. 파일이 손상되지 않았는지 확인하세요."
        case .wrongFormat:
            "Pinpage 설정 파일이 아닙니다. 설정 탭의 [설정 내보내기]로 만든 파일을 선택하세요."
        case .newerSchema(let version):
            "더 새로운 버전의 Pinpage에서 만든 설정 파일입니다(형식 버전 \(version)). 앱을 최신 버전으로 바꾼 뒤 불러오세요."
        case .invalidValues(let issues):
            "설정 파일에 잘못된 값이 있습니다.\n" + issues.map { "• " + $0.description }.joined(separator: "\n")
        }
    }
}

public enum SettingsTransfer {
    /// 내보내기 파일 내용. API 키는 포함하지 않는다.
    public static func exportData(_ settings: AppSettings, appVersion: String, now: Date = Date()) throws -> Data {
        let file = SettingsExportFile(
            format: SettingsExportFile.formatIdentifier,
            schemaVersion: AppSettings.currentSchemaVersion,
            appVersion: appVersion,
            exportedAt: iso8601(now),
            settings: settings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.userInfo[.excludeSecrets] = true
        return try encoder.encode(file)
    }

    /// 내보내기 파일을 읽어 새 설정을 만든다.
    /// API 키는 파일 내용과 관계없이 항상 `current`의 값을 유지한다.
    public static func importSettings(from data: Data, keepingSecretsFrom current: AppSettings) throws(SettingsImportError) -> AppSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .notJSON
        }
        guard object["format"] as? String == SettingsExportFile.formatIdentifier else {
            throw .wrongFormat
        }
        if let version = object["schemaVersion"] as? Int, version > AppSettings.currentSchemaVersion {
            throw .newerSchema(version)
        }
        guard let file = try? JSONDecoder().decode(SettingsExportFile.self, from: data) else {
            throw .wrongFormat
        }

        var settings = file.settings
        settings.schemaVersion = AppSettings.currentSchemaVersion
        settings.chat.apiKey = current.chat.apiKey
        settings.embedding.apiKey = current.embedding.apiKey

        let issues = settings.validate()
        guard issues.isEmpty else { throw .invalidValues(issues) }
        return settings
    }

    /// 저장 창의 기본 파일 이름 (예: pinpage-settings-20261028-1530.json)
    public static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "pinpage-settings-\(formatter.string(from: now)).json"
    }

    static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
