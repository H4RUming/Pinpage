import Foundation

/// 근거 위치를 사람이 읽는 문구로 만든다. 프롬프트와 화면이 같은 문구를 쓴다.
public enum CitationLabel {
    /// 예: "강의자료.pdf · 12쪽 · 2번째 문단", "강의자료.pdf · 3쪽 · 1~2번째 문단"
    public static func text(fileName: String, chunk: Chunk) -> String {
        "\(fileName) · \(chunk.pageIndex + 1)쪽 · \(paragraphs(chunk))"
    }

    public static func paragraphs(_ chunk: Chunk) -> String {
        chunk.paragraphStart == chunk.paragraphEnd
            ? "\(chunk.paragraphStart + 1)번째 문단"
            : "\(chunk.paragraphStart + 1)~\(chunk.paragraphEnd + 1)번째 문단"
    }
}

/// 검색 결과를 번호 붙인 근거 목록으로 만든다 (`{{sources}}`).
public enum SourceBlock {
    public static func render(_ hits: [SearchHit]) -> String {
        hits.enumerated().map { index, hit in
            "[\(index + 1)] \(CitationLabel.text(fileName: hit.document.fileName, chunk: hit.chunk))\n\(hit.chunk.text)"
        }.joined(separator: "\n\n")
    }
}

/// LLM 응답(JSON)의 형식.
public enum ResponseSchema {
    /// 답변과 2·3단계 힌트: 상태, 본문, 근거(번호와 인용)
    public static var grounded: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["status", "answer", "citations"],
        "properties": [
            "status": ["type": "string", "enum": ["answered", "not_in_materials"]],
            "answer": ["type": "string"],
            "citations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["source", "quote"],
                    "properties": ["source": ["type": "integer"], "quote": ["type": "string"]],
                ],
            ],
        ],
    ] }

    /// 1단계 힌트: 읽어야 할 근거 번호만
    public static var locations: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["status", "sources"],
        "properties": [
            "status": ["type": "string", "enum": ["answered", "not_in_materials"]],
            "sources": ["type": "array", "items": ["type": "integer"]],
        ],
    ] }
}

struct RawGroundedResponse: Decodable {
    struct Citation: Decodable {
        let source: Int
        let quote: String?
    }
    let status: String
    let answer: String?
    let citations: [Citation]?
}

struct RawLocationsResponse: Decodable {
    let status: String
    let sources: [Int]?
}

enum ResponseParser {
    /// 응답에서 JSON 객체를 꺼낸다. ```json 블록이나 앞뒤 문장이 붙어 있어도 첫 `{`부터 마지막 `}`까지 읽는다.
    static func decode<T: Decodable>(_ type: T.Type, from content: String) -> T? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(content[start...end].utf8))
    }
}

/// 인용이 실제로 근거 청크에 있는지 확인한다.
/// 공백, 문장부호, 대소문자, 호환 문자 차이는 무시한다. 그대로 들어 있지 않으면
/// 가장 긴 공통 부분이 인용의 `minimumRatio` 이상일 때만 인정한다.
public enum QuoteVerifier {
    public static let minimumRatio = 0.8
    public static let minimumLength = 4

    public static func verify(quote: String, in text: String) -> Bool {
        let q = normalize(quote)
        guard q.count >= minimumLength else { return false }
        let t = normalize(text)
        if t.count >= q.count, contains(t, q) { return true }
        return Double(longestCommonSubstring(q, t)) / Double(q.count) >= minimumRatio
    }

    /// 글자와 숫자만 남긴다 (호환 문자 정규화, 소문자).
    static func normalize(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func contains(_ haystack: [Character], _ needle: [Character]) -> Bool {
        firstIndex(of: needle, in: haystack, from: 0, to: haystack.count) != nil
    }

    static func firstIndex(of needle: [Character], in haystack: [Character], from: Int, to: Int) -> Int? {
        guard !needle.isEmpty, to - from >= needle.count else { return nil }
        var i = from
        while i <= to - needle.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    static func longestCommonSubstring(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var best = 0
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }
}

/// 인용 문장이 페이지 텍스트의 어디에 있는지 찾는다 (PDF 뷰어 강조용).
/// 줄바꿈·공백·문장부호 차이를 무시하고 찾은 뒤 원래 텍스트의 UTF-16 범위로 돌려준다.
public enum HighlightLocator {
    public static func range(of quote: String, in pageText: String, within limit: NSRange? = nil) -> NSRange? {
        let needle = QuoteVerifier.normalize(quote)
        guard needle.count >= QuoteVerifier.minimumLength else { return nil }

        let ns = pageText as NSString
        let scope = limit.map { NSIntersectionRange($0, NSRange(location: 0, length: ns.length)) }
            ?? NSRange(location: 0, length: ns.length)
        var characters: [Character] = []
        var sources: [NSRange] = []
        ns.enumerateSubstrings(in: scope, options: .byComposedCharacterSequences) { substring, range, _, _ in
            guard let substring else { return }
            for ch in substring.precomposedStringWithCompatibilityMapping.lowercased() where ch.isLetter || ch.isNumber {
                characters.append(ch)
                sources.append(range)
            }
        }
        guard let start = QuoteVerifier.firstIndex(of: needle, in: characters, from: 0, to: characters.count) else { return nil }
        let first = sources[start], last = sources[start + needle.count - 1]
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
