import Foundation

/// CSV 열 하나: 열 이름과 한 줄에서 값을 꺼내는 방법.
/// 헤더와 값을 같은 목록에서 만들므로 열 이름과 값의 순서가 어긋날 수 없다.
public struct CSVColumn<Row>: Sendable {
    public let name: String
    let value: @Sendable (Row) -> String

    public init(_ name: String, _ value: @escaping @Sendable (Row) -> String) {
        self.name = name
        self.value = value
    }
}

/// RFC 4180 형식 CSV.
/// - Excel에서 한글이 깨지지 않도록 UTF-8 BOM을 붙인다.
/// - 줄 끝은 CRLF. 쉼표, 큰따옴표, 줄바꿈이 든 값은 큰따옴표로 감싸고 안의 큰따옴표는 두 번 쓴다.
/// - 값이 없으면 빈 칸.
public enum CSV {
    public static let byteOrderMark = "\u{FEFF}"
    public static let lineEnding = "\r\n"

    public static func encode<Row>(_ rows: [Row], columns: [CSVColumn<Row>]) -> Data {
        var text = byteOrderMark + line(columns.map(\.name))
        for row in rows {
            text += line(columns.map { $0.value(row) })
        }
        return Data(text.utf8)
    }

    public static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + lineEnding
    }

    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - 값 형식 (모든 파일에서 같게)

    public static func int(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    public static func bool(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? ""
    }

    /// 0~1 비율, 소수점 넷째 자리까지
    public static func ratio(_ value: Double?) -> String {
        value.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
    }

    /// UTC, 밀리초까지 (이벤트 로그와 같은 형식)
    public static func time(_ date: Date?) -> String {
        date.map(EventLogger.timestamp) ?? ""
    }
}
