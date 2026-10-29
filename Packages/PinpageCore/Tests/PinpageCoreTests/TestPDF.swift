import AppKit
import CoreText
import Foundation

/// 내용을 알고 있는 테스트용 PDF를 만든다.
enum TestPDF {
    static let pageSize = CGSize(width: 595, height: 842)  // A4

    /// - Parameters:
    ///   - pages: 페이지별 문단 목록
    ///   - imageOnlyPages: 텍스트 없이 이미지로만 그릴 페이지 (스캔본 흉내, OCR 대상)
    /// - Parameter textWidth: 글을 채울 폭 (기본: 페이지 폭 - 여백 120)
    static func make(pages: [[String]], imageOnlyPages: Set<Int> = [], textWidth: CGFloat? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-test-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for (index, paragraphs) in pages.enumerated() {
            context.beginPDFPage(nil)
            if imageOnlyPages.contains(index) {
                let image = try renderImage(paragraphs, textWidth: textWidth)
                context.draw(image, in: box)
            } else {
                drawText(paragraphs, in: context, size: pageSize, fontSize: 12, textWidth: textWidth)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    enum WordLayout {
        /// 어절 단위 줄바꿈, 왼쪽 정렬
        case left
        /// 어절 단위 줄바꿈, 양쪽 정렬 (단어 사이 간격을 늘려 줄 끝을 맞춘다)
        case justified
    }

    /// 어절 단위로 줄을 직접 나눠 그린다 (Word, 한글 등에서 만든 PDF 흉내).
    static func makeWordWrapped(paragraphs: [String], layout: WordLayout, width: CGFloat = 300) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-wrap-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let font = NSFont(name: "AppleSDGothicNeo-Regular", size: 12) ?? NSFont.systemFont(ofSize: 12)
        func line(_ s: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        }
        func advance(_ s: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(s), nil, nil, nil)) }

        context.beginPDFPage(nil)
        var y: CGFloat = 780
        for paragraph in paragraphs {
            var lines: [[String]] = []
            var current: [String] = []
            for word in paragraph.split(separator: " ").map(String.init) {
                if !current.isEmpty, advance((current + [word]).joined(separator: " ")) > width {
                    lines.append(current)
                    current = [word]
                } else {
                    current.append(word)
                }
            }
            lines.append(current)
            for (index, words) in lines.enumerated() {
                let isLast = index == lines.count - 1
                if layout == .justified, !isLast, words.count > 1 {
                    // Word처럼 공백 글자는 남기고 공백의 폭만 늘려 줄 끝을 맞춘다.
                    let joined = words.joined(separator: " ")
                    let extra = (width - advance(joined)) / CGFloat(words.count - 1)
                    let attributed = NSMutableAttributedString(string: joined, attributes: [.font: font])
                    var location = 0
                    for word in words.dropLast() {
                        location += (word as NSString).length
                        attributed.addAttribute(.kern, value: extra, range: NSRange(location: location, length: 1))
                        location += 1
                    }
                    context.textPosition = CGPoint(x: 60, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                } else {
                    context.textPosition = CGPoint(x: 60, y: y)
                    CTLineDraw(line(words.joined(separator: " ")), context)
                }
                y -= 16
            }
            y -= 14
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func attributed(_ paragraphs: [String], fontSize: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = fontSize * 1.5
        style.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "AppleSDGothicNeo-Regular", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: style,
            .foregroundColor: NSColor.black,
        ]
        return NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: attributes)
    }

    private static func drawText(_ paragraphs: [String], in context: CGContext, size: CGSize, fontSize: CGFloat, textWidth: CGFloat? = nil) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(paragraphs, fontSize: fontSize))
        let path = CGPath(rect: CGRect(x: 60, y: 60, width: textWidth ?? size.width - 120, height: size.height - 120), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func renderImage(_ paragraphs: [String], textWidth: CGFloat? = nil) throws -> CGImage {
        let scale: CGFloat = 2
        let width = Int(pageSize.width * scale), height = Int(pageSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        drawText(paragraphs, in: context, size: pageSize, fontSize: 16, textWidth: textWidth.map { $0 * 16 / 12 })
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
