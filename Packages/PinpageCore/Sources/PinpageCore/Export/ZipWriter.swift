import Foundation

public enum ZipError: Error, LocalizedError, Equatable {
    case entryTooLarge(String)
    case tooManyEntries

    public var errorDescription: String? {
        switch self {
        case .entryTooLarge(let name): "\(name)이(가) 너무 커서 zip으로 묶을 수 없습니다 (4GB 초과)."
        case .tooManyEntries: "zip에 넣을 파일이 너무 많습니다."
        }
    }
}

/// 압축하지 않고(stored) 파일을 묶는 zip 작성기. 외부 도구 없이 만든다.
/// Finder(아카이브 유틸리티), `unzip`, Python `zipfile`로 열린다.
/// 로그 파일이 4GB를 넘을 일은 없으므로 ZIP64는 지원하지 않는다.
public enum ZipWriter {
    public struct Entry: Sendable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// - Parameter modified: 파일의 수정 시각 (zip에는 시간대 없이 `timeZone` 기준 시각으로 들어간다)
    public static func archive(_ entries: [Entry], modified: Date, timeZone: TimeZone = .current) throws -> Data {
        guard entries.count < Int(UInt16.max) else { throw ZipError.tooManyEntries }
        let (time, date) = dosDateTime(modified, timeZone: timeZone)
        var output = Data()
        var central = Data()

        for entry in entries {
            guard entry.data.count < Int(UInt32.max), output.count < Int(UInt32.max) else {
                throw ZipError.entryTooLarge(entry.name)
            }
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            // 로컬 파일 헤더
            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))          // 풀 때 필요한 버전 2.0
            output.appendLE(utf8Flag)
            output.appendLE(UInt16(0))           // 압축하지 않음
            output.appendLE(time)
            output.appendLE(date)
            output.appendLE(crc)
            output.appendLE(size)                // 압축한 크기
            output.appendLE(size)                // 원래 크기
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))           // 추가 필드 없음
            output.append(name)
            output.append(entry.data)

            // 중앙 디렉터리 항목
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(3 << 8 | 20)) // 만든 곳: Unix, 버전 2.0 (파일 권한을 남기기 위해)
            central.appendLE(UInt16(20))
            central.appendLE(utf8Flag)
            central.appendLE(UInt16(0))
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))          // 추가 필드
            central.appendLE(UInt16(0))          // 설명
            central.appendLE(UInt16(0))          // 디스크 번호
            central.appendLE(UInt16(0))          // 내부 속성
            central.appendLE(UInt32(0o100644) << 16) // 일반 파일, rw-r--r--
            central.appendLE(offset)
            central.append(name)
        }

        guard output.count < Int(UInt32.max) else { throw ZipError.entryTooLarge("zip") }
        let centralOffset = UInt32(output.count)
        output.append(central)
        // 중앙 디렉터리 끝
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    /// 파일 이름이 UTF-8임을 표시하는 플래그 (bit 11)
    private static let utf8Flag = UInt16(0x0800)

    /// MS-DOS 형식 시각과 날짜 (2초 단위, 1980~2107년).
    static func dosDateTime(_ date: Date, timeZone: TimeZone) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }

    /// CRC-32 (IEEE 802.3, zip과 같은 다항식).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
