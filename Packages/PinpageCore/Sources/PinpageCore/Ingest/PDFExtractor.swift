import AppKit
import Foundation
import PDFKit
import Vision

/// PDF 페이지에서 줄 단위 텍스트와 위치를 뽑는다. 텍스트가 없는 페이지(스캔본)는 OCR로 읽는다.
public enum PDFExtractor {
    /// 텍스트 레이어에 글자가 하나도 없으면 OCR 대상이다.
    public static func needsOCR(_ page: PDFPage) -> Bool {
        !(page.string ?? "").contains { !$0.isWhitespace }
    }

    public static func content(of page: PDFPage, index: Int, ocrLanguages: [String]) async throws -> PageContent {
        if needsOCR(page) {
            return try await ocrContent(of: page, index: index, languages: ocrLanguages)
        }
        return textContent(of: page, index: index)
    }

    /// PDF 텍스트 레이어에서 줄과 위치를 얻는다.
    public static func textContent(of page: PDFPage, index: Int) -> PageContent {
        let text = page.string ?? ""
        let ns = text as NSString
        var lines: [TextLine] = []
        var lineStart = 0
        var i = 0
        func addLine(end: Int) {
            let range = NSRange(location: lineStart, length: end - lineStart)
            if range.length > 0,
               let selection = page.selection(for: range) {
                let rect = selection.bounds(for: page)
                if !rect.isEmpty {
                    let first = page.selection(for: NSRange(location: range.location, length: 1))?.bounds(for: page)
                    lines.append(TextLine(text: ns.substring(with: range), rect: rect, range: range,
                                          wordGap: wordGap(in: range, text: ns, page: page),
                                          firstGlyphWidth: first.flatMap { $0.isEmpty ? nil : $0.width }))
                }
            }
        }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 {
                addLine(end: i)
                lineStart = i + 1
            }
            i += 1
        }
        addLine(end: ns.length)
        return PageContent(pageIndex: index, text: text, lines: lines, source: .text)
    }

    /// 줄 안 단어 사이 간격의 중앙값: 공백 앞 글자의 오른쪽 끝과 뒤 글자의 왼쪽 끝 사이.
    /// `characterBounds(at:)`는 줄바꿈 문자를 세지 않아 줄마다 위치가 밀리므로 글자 하나짜리 선택 영역을 쓴다.
    static func wordGap(in range: NSRange, text: NSString, page: PDFPage) -> CGFloat? {
        func bounds(_ index: Int) -> CGRect {
            page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page) ?? .zero
        }
        var gaps: [CGFloat] = []
        let end = NSMaxRange(range)
        var i = range.location + 1
        while i < end - 1 {
            if text.character(at: i) == 0x20,
               text.character(at: i - 1) != 0x20, text.character(at: i + 1) != 0x20 {
                let before = bounds(i - 1)
                let after = bounds(i + 1)
                if !before.isEmpty, !after.isEmpty, after.minX > before.maxX {
                    gaps.append(after.minX - before.maxX)
                }
            }
            i += 1
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// 페이지를 이미지로 그려 Vision으로 읽는다. 맞춤법 교정은 끈다 (코드·수식이 바뀌지 않도록).
    public static func ocrContent(of page: PDFPage, index: Int, languages: [String]) async throws -> PageContent {
        let box = page.bounds(for: .cropBox)
        let longSide: CGFloat = 2500
        let scale = longSide / max(box.width, box.height, 1)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PDFExtractorError.renderFailed(page: index)
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }
        let observations = try await request.perform(on: cgImage)

        // 위에서 아래, 왼쪽에서 오른쪽 순서. 정규화 좌표(원점 왼쪽 아래)를 페이지 좌표로 바꾼다.
        let recognized: [(text: String, rect: CGRect)] = observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let n = observation.boundingBox.cgRect
            let rect = CGRect(x: box.minX + n.minX * box.width, y: box.minY + n.minY * box.height,
                              width: n.width * box.width, height: n.height * box.height)
            return (text, rect)
        }
        .sorted { a, b in
            let tolerance = min(a.rect.height, b.rect.height) * 0.5
            if abs(a.rect.midY - b.rect.midY) > tolerance { return a.rect.midY > b.rect.midY }
            return a.rect.minX < b.rect.minX
        }

        var text = ""
        var lines: [TextLine] = []
        for item in recognized {
            if !text.isEmpty { text += "\n" }
            let location = (text as NSString).length
            text += item.text
            lines.append(TextLine(text: item.text, rect: item.rect,
                                  range: NSRange(location: location, length: (item.text as NSString).length)))
        }
        return PageContent(pageIndex: index, text: text, lines: lines, source: .ocr)
    }
}

public enum PDFExtractorError: Error, LocalizedError {
    case renderFailed(page: Int)
    case cannotOpen

    public var errorDescription: String? {
        switch self {
        case .renderFailed(let page): "\(page + 1)쪽을 이미지로 그릴 수 없어 OCR을 하지 못했습니다."
        case .cannotOpen: "PDF 파일을 열 수 없습니다."
        }
    }
}
