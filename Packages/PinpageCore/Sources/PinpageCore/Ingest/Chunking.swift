import Foundation

/// 페이지의 한 줄. `range`는 페이지 텍스트 안의 UTF-16 범위.
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    public var range: NSRange

    public init(text: String, rect: CGRect, range: NSRange) {
        self.text = text
        self.rect = rect
        self.range = range
    }
}

/// 한 페이지의 내용. OCR 페이지는 인식한 줄을 줄바꿈으로 이어 붙인 텍스트를 쓴다.
public struct PageContent: Sendable {
    public var pageIndex: Int
    public var text: String
    public var lines: [TextLine]
    public var source: ChunkSource

    public init(pageIndex: Int, text: String, lines: [TextLine], source: ChunkSource) {
        self.pageIndex = pageIndex
        self.text = text
        self.lines = lines
        self.source = source
    }
}

public struct Paragraph: Equatable, Sendable {
    /// 페이지 안의 문단 번호 (0부터)
    public var index: Int
    public var lines: [TextLine]
    /// 페이지 텍스트 안의 UTF-16 범위 (첫 줄 시작 ~ 마지막 줄 끝)
    public var range: NSRange
}

/// 줄 위치로 문단을 나눈다.
/// - 줄 사이 세로 간격이 보통 줄 높이의 `gapFactor`배보다 크면 새 문단
/// - 다음 줄이 위로 올라가면(다음 단, 새 영역) 새 문단
/// - 글머리표나 번호(•, -, 1., ①, 가.)로 시작하면 새 문단
public enum ParagraphSegmenter {
    public static let gapFactor: CGFloat = 0.7

    public static func paragraphs(from lines: [TextLine]) -> [Paragraph] {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return [] }

        let heights = lines.map(\.rect.height).filter { $0 > 0 }.sorted()
        let typicalHeight = heights.isEmpty ? 0 : heights[heights.count / 2]

        var groups: [[TextLine]] = [[lines[0]]]
        for (prev, line) in zip(lines, lines.dropFirst()) {
            let gap = prev.rect.minY - line.rect.maxY
            let movedUp = line.rect.minY > prev.rect.maxY
            let bigGap = typicalHeight > 0 && gap > typicalHeight * gapFactor
            if movedUp || bigGap || startsListItem(line.text) {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        return groups.enumerated().map { index, group in
            let start = group[0].range.location
            let end = NSMaxRange(group[group.count - 1].range)
            return Paragraph(index: index, lines: group, range: NSRange(location: start, length: end - start))
        }
    }

    private static let listPattern = try! NSRegularExpression(
        pattern: #"^\s*([•·▪◦‣\-–*]|\d{1,3}[.)]|[①-⑳]|[가-하][.)]|\([0-9가-하]{1,2}\))\s"#
    )

    static func startsListItem(_ text: String) -> Bool {
        listPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// 청크 초안. DB에 넣기 전 상태.
public struct ChunkDraft: Equatable, Sendable {
    public var pageIndex: Int
    public var paragraphStart: Int
    public var paragraphEnd: Int
    /// 페이지 텍스트 안의 UTF-16 범위
    public var range: NSRange
    public var rects: [CGRect]
    public var text: String
}

/// 문단을 청크로 묶는다. 청크는 페이지를 넘지 않는다.
/// - 짧은 문단은 `size`까지 이어 붙인다
/// - `size`보다 긴 문단은 `overlap`만큼 겹치게 자른다 (가능하면 문장 끝이나 공백에서)
/// 길이는 UTF-16 단위로 잰다.
public enum Chunker {
    public static func chunks(page: PageContent, paragraphs: [Paragraph], size: Int, overlap: Int) -> [ChunkDraft] {
        precondition(size > 0 && overlap >= 0 && overlap < size)
        let pageText = page.text as NSString
        var drafts: [ChunkDraft] = []
        var buffer: [Paragraph] = []
        var bufferLength = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let first = buffer[0], last = buffer[buffer.count - 1]
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let text = buffer.map { clean(pageText.substring(with: $0.range)) }.joined(separator: "\n")
            drafts.append(ChunkDraft(
                pageIndex: page.pageIndex, paragraphStart: first.index, paragraphEnd: last.index,
                range: range, rects: buffer.flatMap { $0.lines.map(\.rect) }, text: text
            ))
            buffer = []
            bufferLength = 0
        }

        for paragraph in paragraphs {
            let length = paragraph.range.length
            if length > size {
                flush()
                for window in windows(of: paragraph.range, in: pageText, size: size, overlap: overlap) {
                    let text = clean(pageText.substring(with: window))
                    guard !text.isEmpty else { continue }
                    let rects = paragraph.lines.filter { NSIntersectionRange($0.range, window).length > 0 }.map(\.rect)
                    drafts.append(ChunkDraft(
                        pageIndex: page.pageIndex, paragraphStart: paragraph.index, paragraphEnd: paragraph.index,
                        range: window, rects: rects, text: text
                    ))
                }
                continue
            }
            let separator = buffer.isEmpty ? 0 : 1
            if bufferLength + separator + length > size { flush() }
            bufferLength += (buffer.isEmpty ? 0 : 1) + length
            buffer.append(paragraph)
        }
        flush()
        return drafts.filter { !$0.text.isEmpty }
    }

    /// 긴 범위를 겹치는 창으로 자른다.
    static func windows(of range: NSRange, in text: NSString, size: Int, overlap: Int) -> [NSRange] {
        var result: [NSRange] = []
        let end = NSMaxRange(range)
        var start = range.location
        while start < end {
            var stop = min(start + size, end)
            if stop < end {
                stop = breakPoint(in: text, from: start + size / 2, to: stop) ?? stop
                stop = safeBoundary(text, stop)
            }
            result.append(NSRange(location: start, length: stop - start))
            if stop >= end { break }
            var next = max(stop - overlap, start + 1)
            next = safeBoundary(text, next)
            start = next > start ? next : stop
        }
        return result
    }

    /// (lower, upper] 안에서 마지막 문장 끝(뒤 공백 포함), 없으면 마지막 공백 바로 뒤 위치.
    /// 다음 청크가 문장 첫 글자부터 시작하게 한다.
    private static func breakPoint(in text: NSString, from lower: Int, to upper: Int) -> Int? {
        guard upper > lower else { return nil }
        var lastSpace: Int? = isSpace(text.character(at: upper - 1)) ? upper : nil
        var i = upper - 2
        while i >= lower {
            let c = text.character(at: i)
            if c == 0x2E || c == 0x3F || c == 0x21 || c == 0x3002 {  // . ? ! 。
                if isSpace(text.character(at: i + 1)) { return i + 2 }
            }
            if lastSpace == nil, isSpace(c) { lastSpace = i + 1 }
            i -= 1
        }
        return lastSpace
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
    }

    /// 서로게이트 쌍(이모지 등) 가운데를 자르지 않도록 위치를 맞춘다.
    private static func safeBoundary(_ text: NSString, _ index: Int) -> Int {
        guard index > 0, index < text.length else { return index }
        return text.rangeOfComposedCharacterSequence(at: index).location == index
            ? index
            : NSMaxRange(text.rangeOfComposedCharacterSequence(at: index))
    }

    /// 줄바꿈을 공백으로 바꾸고 연속 공백을 하나로 줄인다.
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
