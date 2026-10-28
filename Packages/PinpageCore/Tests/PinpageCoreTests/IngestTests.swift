import Foundation
import PDFKit
import Testing
@testable import PinpageCore

private let page1 = [
    "파이썬의 리스트는 순서가 있는 가변 자료형이다. 대괄호로 만들고 append로 끝에 원소를 추가할 수 있다.",
    "튜플은 리스트와 비슷하지만 한 번 만들면 원소를 바꿀 수 없는 불변 자료형이다.",
    "딕셔너리는 키와 값의 쌍을 저장하는 자료형이다. 키로 값을 찾는 연산은 평균적으로 상수 시간에 끝난다.",
]
private let page2 = [
    "교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다.",
    "경쟁 상태는 여러 스레드가 공유 데이터에 동시에 접근할 때 실행 순서에 따라 결과가 달라지는 문제다.",
]

@Suite("PDF 텍스트 추출과 청크 위치")
struct PDFIngestTests {
    @Test("페이지와 문단을 정확히 나누고 청크마다 위치를 가진다")
    func textPDF() async throws {
        let url = try TestPDF.make(pages: [page1, page2])
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount == 2)

        for (pageIndex, expected) in [page1, page2].enumerated() {
            let page = try #require(pdf.page(at: pageIndex))
            #expect(!PDFExtractor.needsOCR(page))
            let content = PDFExtractor.textContent(of: page, index: pageIndex)
            let paragraphs = ParagraphSegmenter.paragraphs(from: content.lines)
            #expect(paragraphs.count == expected.count, "\(pageIndex + 1)쪽 문단 수")

            // 문단마다 하나씩 청크가 되도록 작은 크기로 자른다.
            let drafts = Chunker.chunks(page: content, paragraphs: paragraphs, size: 60, overlap: 10)
            #expect(!drafts.isEmpty)
            let pageText = content.text as NSString
            for draft in drafts {
                #expect(draft.pageIndex == pageIndex)
                #expect(!draft.rects.isEmpty)
                #expect(draft.rects.allSatisfy { page.bounds(for: .mediaBox).insetBy(dx: -1, dy: -1).contains($0) })
                // 저장한 글자 범위가 실제로 그 텍스트를 가리킨다.
                let located = Chunker.clean(pageText.substring(with: draft.range))
                #expect(located.contains(draft.text) || draft.text.contains(located), "\(draft.text)")
            }
            // 문단 순서대로, 빠짐없이 들어 있다.
            for (index, paragraph) in expected.enumerated() {
                let words = paragraph.split(separator: " ").prefix(3).joined(separator: " ")
                let owner = drafts.first { $0.text.contains(words) }
                #expect(owner != nil, "'\(words)' 를 담은 청크가 없음")
                #expect(owner.map { $0.paragraphStart...$0.paragraphEnd ~= index } == true)
            }
        }
    }

    @Test("짧은 문단은 청크 크기까지 합친다")
    func mergesParagraphs() throws {
        let url = try TestPDF.make(pages: [page1])
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let content = PDFExtractor.textContent(of: page, index: 0)
        let paragraphs = ParagraphSegmenter.paragraphs(from: content.lines)
        let drafts = Chunker.chunks(page: content, paragraphs: paragraphs, size: 800, overlap: 100)
        #expect(drafts.count == 1)
        #expect(drafts[0].paragraphStart == 0)
        #expect(drafts[0].paragraphEnd == paragraphs.count - 1)
        #expect(drafts[0].text.contains("튜플은"))
        #expect(drafts[0].text.contains("딕셔너리는"))
    }

    @Test("텍스트 없는 페이지는 OCR로 읽고 위치를 가진다")
    func scannedPage() async throws {
        let url = try TestPDF.make(pages: [page1, page2], imageOnlyPages: [1])
        defer { try? FileManager.default.removeItem(at: url) }
        let pdf = try #require(PDFDocument(url: url))
        let textPage = try #require(pdf.page(at: 0))
        let scanned = try #require(pdf.page(at: 1))
        #expect(!PDFExtractor.needsOCR(textPage))
        #expect(PDFExtractor.needsOCR(scanned))

        let content = try await PDFExtractor.content(of: scanned, index: 1, ocrLanguages: ["ko-KR", "en-US"])
        #expect(content.source == .ocr)
        let joined = content.text.replacingOccurrences(of: "\n", with: " ")
        #expect(joined.contains("교착 상태"), "\(joined)")
        #expect(joined.contains("경쟁 상태"))
        let bounds = scanned.bounds(for: .cropBox).insetBy(dx: -1, dy: -1)
        #expect(content.lines.allSatisfy { bounds.contains($0.rect) })

        let paragraphs = ParagraphSegmenter.paragraphs(from: content.lines)
        #expect(paragraphs.count == 2)
        let drafts = Chunker.chunks(page: content, paragraphs: paragraphs, size: 800, overlap: 100)
        #expect(drafts.allSatisfy { $0.pageIndex == 1 && !$0.rects.isEmpty })
    }
}

@Suite("문단 나누기")
struct ParagraphSegmenterTests {
    private func line(_ text: String, y: CGFloat, x: CGFloat = 50, height: CGFloat = 12, at location: Int) -> TextLine {
        TextLine(text: text, rect: CGRect(x: x, y: y, width: 300, height: height),
                 range: NSRange(location: location, length: (text as NSString).length))
    }

    @Test("줄 간격이 크면 새 문단")
    func gaps() {
        let lines = [
            line("첫 문단 첫 줄", y: 700, at: 0),
            line("첫 문단 둘째 줄", y: 685, at: 8),   // 간격 3 → 같은 문단
            line("둘째 문단", y: 650, at: 18),        // 간격 23 → 새 문단
        ]
        let paragraphs = ParagraphSegmenter.paragraphs(from: lines)
        #expect(paragraphs.map(\.lines.count) == [2, 1])
        #expect(paragraphs.map(\.index) == [0, 1])
        #expect(paragraphs[0].range == NSRange(location: 0, length: 17))
    }

    @Test("글머리표와 번호는 새 문단")
    func listItems() {
        #expect(ParagraphSegmenter.startsListItem("• 항목"))
        #expect(ParagraphSegmenter.startsListItem("- 항목"))
        #expect(ParagraphSegmenter.startsListItem("1. 항목"))
        #expect(ParagraphSegmenter.startsListItem("12) 항목"))
        #expect(ParagraphSegmenter.startsListItem("① 항목"))
        #expect(ParagraphSegmenter.startsListItem("가. 항목"))
        #expect(ParagraphSegmenter.startsListItem("(3) 항목"))
        #expect(!ParagraphSegmenter.startsListItem("2024년에는"))
        #expect(!ParagraphSegmenter.startsListItem("가나다"))
    }

    @Test("위로 올라가면(다음 단) 새 문단, 빈 줄은 무시")
    func movedUpAndBlank() {
        let lines = [
            line("왼쪽 단 끝", y: 100, at: 0),
            line("   ", y: 90, at: 7),
            line("오른쪽 단 시작", y: 700, x: 320, at: 11),
        ]
        #expect(ParagraphSegmenter.paragraphs(from: lines).count == 2)
    }
}

@Suite("청크 자르기")
struct ChunkerTests {
    @Test("긴 문단은 크기 이하로, 겹치게, 빠짐없이 자른다")
    func windows() {
        let sentence = "교착 상태는 프로세스가 서로의 자원을 기다리며 멈춘 상태다. "
        let text = String(repeating: sentence, count: 30) as NSString
        let range = NSRange(location: 0, length: text.length)
        let windows = Chunker.windows(of: range, in: text, size: 200, overlap: 40)
        #expect(windows.count > 1)
        #expect(windows.first?.location == 0)
        #expect(windows.last.map(NSMaxRange) == text.length)
        for w in windows { #expect(w.length <= 200 && w.length > 0) }
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(b.location > a.location)           // 앞으로 나아간다
            #expect(b.location <= NSMaxRange(a))       // 틈이 없다
            #expect(NSMaxRange(a) - b.location <= 60)  // 겹침은 대략 overlap
        }
        // 문장 끝에서 자른다.
        #expect(text.substring(with: windows[0]).hasSuffix("상태다. "))
    }

    @Test("이모지(서로게이트 쌍) 가운데를 자르지 않는다")
    func surrogatePairs() {
        let text = String(repeating: "😀", count: 100) as NSString  // UTF-16 200
        let windows = Chunker.windows(of: NSRange(location: 0, length: text.length), in: text, size: 33, overlap: 5)
        for w in windows {
            #expect(w.location % 2 == 0)
            #expect(NSMaxRange(w) % 2 == 0)
        }
    }

    @Test("긴 문단을 자른 청크도 문단 번호와 범위를 가진다")
    func longParagraph() {
        let body = String(repeating: "경쟁 상태는 실행 순서에 따라 결과가 달라지는 문제다. ", count: 20)
        let ns = body as NSString
        let lines = [TextLine(text: body, rect: CGRect(x: 0, y: 0, width: 10, height: 10), range: NSRange(location: 0, length: ns.length))]
        let page = PageContent(pageIndex: 3, text: body, lines: lines, source: .text)
        let paragraphs = ParagraphSegmenter.paragraphs(from: lines)
        let drafts = Chunker.chunks(page: page, paragraphs: paragraphs, size: 150, overlap: 30)
        #expect(drafts.count > 1)
        for d in drafts {
            #expect(d.pageIndex == 3 && d.paragraphStart == 0 && d.paragraphEnd == 0)
            #expect(Chunker.clean(ns.substring(with: d.range)) == d.text)
        }
    }

    @Test("공백 정리")
    func clean() {
        #expect(Chunker.clean("  가\n나\t\t다  ") == "가 나 다")
    }
}
