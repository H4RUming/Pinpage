import Foundation

/// 문서의 줄바꿈 방식.
public enum WrapStyle: Equatable, Sendable {
    /// 공백 자리에서 줄을 바꾼다 (대부분의 문서). 줄바꿈은 공백으로 잇는다.
    case wordWrap
    /// 글자 단위로 줄을 바꿔 단어 중간에서도 줄이 바뀐다. 한글과 한글 사이의 줄바꿈은 공백 없이 잇는다.
    case characterWrap
}

/// 줄을 이어 붙일 때 공백을 넣을지 정한다.
///
/// PDFKit은 줄 끝 공백을 지우므로 "프\n로토콜"(단어 중간)과 "있는\n프로토콜"(공백 자리)을 텍스트로는 구분할 수 없다.
/// 그래서 글자 위치로 문서의 줄바꿈 방식을 먼저 판정한다.
/// - 글자 단위 줄바꿈이면 문단 안의 줄이 모두 오른쪽 끝에서 한 글자 폭 안쪽에서 끝난다.
/// - 어절 단위 줄바꿈이면 줄 끝 빈칸이 들쭉날쭉하다 (한 글자 폭 이상 남는 줄이 많다).
/// - 양쪽 정렬이면 어절 단위여도 줄 끝이 맞는다. 이때는 단어 사이 간격이 늘어나 있는지로 구분한다.
/// 판단이 애매하면 공백을 넣는다 (단어가 붙는 것보다 안전).
public enum LineJoiner {
    /// 판정에 필요한 최소 줄바꿈 수. 이보다 적으면 어절 단위로 본다.
    static let minimumBreaks = 4
    /// 한 글자 폭 이상 남는 줄이 이 비율 이상이면 어절 단위.
    static let looseRatio = 0.2
    /// 줄 끝 단어 간격이 보통 간격의 이 배수보다 크면 양쪽 정렬로 본다.
    static let stretchRatio = 1.3

    /// 문서 전체의 페이지로 줄바꿈 방식을 판정한다.
    public static func style(pages: [(content: PageContent, paragraphs: [Paragraph])]) -> WrapStyle {
        var tight = 0, loose = 0
        var tightGaps: [CGFloat] = []
        var referenceGaps: [CGFloat] = []

        for (content, paragraphs) in pages {
            guard let right = rightEdge(of: content.lines) else { continue }
            for paragraph in paragraphs {
                for (index, line) in paragraph.lines.enumerated() {
                    let isLast = index == paragraph.lines.count - 1
                    if isLast {
                        // 문단 마지막 줄은 양쪽 정렬되지 않으므로 보통 단어 간격의 기준이 된다.
                        if let gap = line.wordGap { referenceGaps.append(gap / em(line)) }
                        continue
                    }
                    if right - line.rect.maxX < em(line) {
                        tight += 1
                        if let gap = line.wordGap { tightGaps.append(gap / em(line)) }
                    } else {
                        loose += 1
                    }
                }
            }
        }

        let total = tight + loose
        guard total >= minimumBreaks else { return .wordWrap }
        if Double(loose) / Double(total) >= looseRatio { return .wordWrap }

        // 줄 끝이 모두 맞는다: 글자 단위 줄바꿈이거나 양쪽 정렬된 어절 단위 줄바꿈.
        guard let tightGap = median(tightGaps) else { return .characterWrap }
        let normal = median(referenceGaps) ?? 0.33  // 보통 공백은 글자 크기의 1/4~1/3
        return tightGap > normal * stretchRatio ? .wordWrap : .characterWrap
    }

    /// 공백 없이 이을 줄바꿈 문자의 위치 (페이지 텍스트의 UTF-16 위치).
    public static func softBreaks(page: PageContent, paragraphs: [Paragraph], style: WrapStyle) -> Set<Int> {
        guard style == .characterWrap, let right = rightEdge(of: page.lines) else { return [] }
        // 본문 오른쪽 끝의 하한 (어떤 줄도 이보다 오른쪽으로 나가지 않았다).
        let frameRight = page.lines.map(\.rect.maxX).max() ?? right
        let text = page.text as NSString
        var breaks = Set<Int>()
        for paragraph in paragraphs {
            for (line, next) in zip(paragraph.lines, paragraph.lines.dropFirst()) {
                guard right - line.rect.maxX < em(line),
                      let last = lastCharacter(of: line.text), isHangulSyllable(last),
                      let first = next.text.first, isHangulSyllable(first)
                else { continue }
                // 다음 줄 첫 글자가 앞 줄 끝에 들어갈 자리가 있었다면, 글자가 모자라서가 아니라
                // 공백 자리에서 줄이 바뀐 것이다 (PDFKit이 줄 끝 공백을 지워 텍스트로는 알 수 없다).
                if let width = next.firstGlyphWidth, line.rect.maxX + width <= frameRight - 0.5 { continue }
                // 두 줄 사이에 줄바꿈 문자만 있을 때 그 문자들을 지운다.
                let between = NSRange(location: NSMaxRange(line.range), length: next.range.location - NSMaxRange(line.range))
                guard between.length > 0, between.location + between.length <= text.length else { continue }
                let separator = text.substring(with: between)
                guard separator.allSatisfy({ $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { continue }
                for i in between.location..<NSMaxRange(between) { breaks.insert(i) }
            }
        }
        return breaks
    }

    /// 줄 끝 공백이 지워진 상태의 마지막 글자 (공백이 남아 있으면 nil → 공백 자리 줄바꿈).
    private static func lastCharacter(of text: String) -> Character? {
        guard let last = text.last, !last.isWhitespace else { return nil }
        return last
    }

    /// 본문 오른쪽 끝. 짧은 줄의 영향을 받지 않도록 상위 10% 지점을 쓴다.
    static func rightEdge(of lines: [TextLine]) -> CGFloat? {
        let edges = lines.map(\.rect.maxX).sorted()
        guard !edges.isEmpty else { return nil }
        return edges[min(edges.count - 1, Int(Double(edges.count) * 0.9))]
    }

    /// 글자 크기 추정 (줄 높이는 글자 크기의 약 1.2배).
    static func em(_ line: TextLine) -> CGFloat {
        max(line.rect.height / 1.2, 1)
    }

    static func isHangulSyllable(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
