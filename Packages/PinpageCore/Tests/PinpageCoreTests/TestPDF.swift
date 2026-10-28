import AppKit
import CoreText
import Foundation

/// 내용을 알고 있는 테스트용 PDF를 만든다.
enum TestPDF {
    static let pageSize = CGSize(width: 595, height: 842)  // A4

    /// - Parameters:
    ///   - pages: 페이지별 문단 목록
    ///   - imageOnlyPages: 텍스트 없이 이미지로만 그릴 페이지 (스캔본 흉내, OCR 대상)
    static func make(pages: [[String]], imageOnlyPages: Set<Int> = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-test-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for (index, paragraphs) in pages.enumerated() {
            context.beginPDFPage(nil)
            if imageOnlyPages.contains(index) {
                let image = try renderImage(paragraphs)
                context.draw(image, in: box)
            } else {
                drawText(paragraphs, in: context, size: pageSize, fontSize: 12)
            }
            context.endPDFPage()
        }
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

    private static func drawText(_ paragraphs: [String], in context: CGContext, size: CGSize, fontSize: CGFloat) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(paragraphs, fontSize: fontSize))
        let path = CGPath(rect: CGRect(x: 60, y: 60, width: size.width - 120, height: size.height - 120), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func renderImage(_ paragraphs: [String]) throws -> CGImage {
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
        drawText(paragraphs, in: context, size: pageSize, fontSize: 16)
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
