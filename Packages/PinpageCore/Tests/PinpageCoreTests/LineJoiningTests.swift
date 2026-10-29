import Foundation
import PDFKit
import Testing
@testable import PinpageCore

/// 여러 줄에 걸치는 긴 한국어 문단들.
private let paragraphs = [
    "TCP는 연결을 맺은 뒤 데이터를 순서대로 빠짐없이 전달하는 신뢰성 있는 프로토콜이다. 연결을 맺을 때 3방향 핸드셰이크를 거치고 손실된 패킷은 다시 보낸다.",
    "교착 상태는 둘 이상의 프로세스가 서로 상대가 가진 자원을 기다리며 영원히 멈춘 상태다. 상호 배제와 점유 대기와 비선점과 순환 대기 네 조건이 모두 성립할 때 생긴다.",
    "경사 하강법은 손실 함수의 기울기 반대 방향으로 매개변수를 조금씩 움직여 손실을 줄인다. 학습률이 너무 크면 발산하고 너무 작으면 학습이 느려진다.",
]

/// PDF를 끝까지 처리했을 때 문단별 청크 텍스트 (색인기와 같은 순서로 판정한다).
private func chunkTexts(_ url: URL, ocr: Bool = false) async throws -> (style: WrapStyle, texts: [String]) {
    let pdf = try #require(PDFDocument(url: url))
    let page = try #require(pdf.page(at: 0))
    let content = ocr
        ? try await PDFExtractor.ocrContent(of: page, index: 0, languages: ["ko-KR", "en-US"])
        : PDFExtractor.textContent(of: page, index: 0)
    let paragraphs = ParagraphSegmenter.paragraphs(from: content.lines)
    let style = LineJoiner.style(pages: [(content, paragraphs)])
    let soft = LineJoiner.softBreaks(page: content, paragraphs: paragraphs, style: style)
    let drafts = Chunker.chunks(page: content, paragraphs: paragraphs, size: 2000, overlap: 0, minLength: 0, softBreaks: soft)
    return (style, drafts.map(\.text))
}

private func words(_ text: String) -> [String] {
    text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
}

@Suite("줄바꿈 이어 붙이기")
struct LineJoiningTests {
    @Test("글자 단위 줄바꿈 문서: 단어 중간 줄바꿈에 공백을 넣지 않는다")
    func characterWrap() async throws {
        let url = try TestPDF.make(pages: [paragraphs], textWidth: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await chunkTexts(url)
        #expect(result.style == .characterWrap)
        #expect(result.texts.count == paragraphs.count)
        for (text, original) in zip(result.texts, paragraphs) {
            // 모든 단어가 쪼개지지 않고 들어 있다 (공백 자리 줄바꿈은 붙을 수 있다).
            for word in words(original) {
                #expect(text.contains(word), "'\(word)'이(가) 쪼개짐: \(text)")
            }
        }
    }

    @Test("어절 단위 줄바꿈(왼쪽 정렬): 줄바꿈 자리에 공백을 넣어 원문과 같다")
    func wordWrapLeft() async throws {
        let url = try TestPDF.makeWordWrapped(paragraphs: paragraphs, layout: .left)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await chunkTexts(url)
        #expect(result.style == .wordWrap)
        #expect(result.texts == paragraphs)
    }

    @Test("어절 단위 줄바꿈(양쪽 정렬): 줄 끝이 맞아도 단어 간격으로 알아보고 공백을 넣는다")
    func wordWrapJustified() async throws {
        let url = try TestPDF.makeWordWrapped(paragraphs: paragraphs, layout: .justified)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await chunkTexts(url)
        #expect(result.style == .wordWrap)
        #expect(result.texts == paragraphs)
    }

    @Test("스캔(OCR) 페이지도 글자 단위 줄바꿈을 이어 붙인다")
    func ocrCharacterWrap() async throws {
        let url = try TestPDF.make(pages: [paragraphs], imageOnlyPages: [0], textWidth: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await chunkTexts(url, ocr: true)
        #expect(result.style == .characterWrap)
        let joined = result.texts.joined(separator: " ")
        let all = paragraphs.flatMap(words)
        let found = all.filter { joined.contains($0) }.count
        // OCR 오인식을 감안해 95% 이상의 단어가 쪼개지지 않고 들어 있으면 통과
        #expect(Double(found) / Double(all.count) >= 0.95, "\(found)/\(all.count): \(joined)")
    }

    @Test("줄바꿈이 너무 적으면 판정하지 않고 공백을 넣는다")
    func tooFewBreaks() {
        let lines = [
            TextLine(text: "가나다라마바사", rect: CGRect(x: 0, y: 100, width: 300, height: 14), range: NSRange(location: 0, length: 7)),
            TextLine(text: "아자차카", rect: CGRect(x: 0, y: 84, width: 120, height: 14), range: NSRange(location: 8, length: 4)),
        ]
        let page = PageContent(pageIndex: 0, text: "가나다라마바사\n아자차카", lines: lines, source: .text)
        let paragraphs = ParagraphSegmenter.paragraphs(from: lines)
        #expect(LineJoiner.style(pages: [(page, paragraphs)]) == .wordWrap)
        #expect(LineJoiner.softBreaks(page: page, paragraphs: paragraphs, style: .wordWrap).isEmpty)
        // 글자 단위로 판정되면 한글 사이 줄바꿈만 지운다.
        #expect(LineJoiner.softBreaks(page: page, paragraphs: paragraphs, style: .characterWrap) == [7])
    }

    @Test("다음 줄 첫 글자가 앞 줄 끝에 들어갈 수 있었으면 공백 자리 줄바꿈으로 본다")
    func roomForNextGlyph() {
        func page(firstWidth: CGFloat) -> (PageContent, [Paragraph]) {
            let lines = [
                TextLine(text: "가나다라", rect: CGRect(x: 0, y: 100, width: 290, height: 14), range: NSRange(location: 0, length: 4)),
                TextLine(text: "마바사아", rect: CGRect(x: 0, y: 84, width: 300, height: 14), range: NSRange(location: 5, length: 4),
                         firstGlyphWidth: firstWidth),
                TextLine(text: "AB", rect: CGRect(x: 0, y: 68, width: 50, height: 14), range: NSRange(location: 10, length: 2)),
            ]
            let content = PageContent(pageIndex: 0, text: "가나다라\n마바사아\nAB", lines: lines, source: .text)
            return (content, [Paragraph(index: 0, lines: lines, range: NSRange(location: 0, length: 12))])
        }
        // 앞 줄 끝(290)에서 오른쪽 끝(300)까지 10pt 남음: 9pt 글자는 들어갔을 것 → 공백 자리
        let (fits, fitsParagraphs) = page(firstWidth: 9)
        #expect(LineJoiner.softBreaks(page: fits, paragraphs: fitsParagraphs, style: .characterWrap).isEmpty)
        // 11pt 글자는 안 들어감 → 단어 중간
        let (noRoom, noRoomParagraphs) = page(firstWidth: 11)
        #expect(LineJoiner.softBreaks(page: noRoom, paragraphs: noRoomParagraphs, style: .characterWrap) == [4])
    }

    @Test("한글이 아닌 글자 사이, 짧은 줄 끝은 이어 붙이지 않는다")
    func onlyHangulAtFullLines() {
        // (줄 텍스트, 줄 폭): 300이면 가득 찬 줄
        let spec: [(String, CGFloat)] = [("binary search는", 300), ("tree에서", 300), ("짧은 줄", 100), ("다음 줄", 300)]
        let text = spec.map(\.0).joined(separator: "\n")
        var location = 0
        var lines: [TextLine] = []
        for (index, (lineText, width)) in spec.enumerated() {
            let length = (lineText as NSString).length
            lines.append(TextLine(text: lineText, rect: CGRect(x: 0, y: CGFloat(100 - index * 16), width: width, height: 14),
                                  range: NSRange(location: location, length: length)))
            location += length + 1
        }
        let page = PageContent(pageIndex: 0, text: text, lines: lines, source: .text)
        let paragraph = Paragraph(index: 0, lines: lines, range: NSRange(location: 0, length: (text as NSString).length))
        // "는\nt": 다음 글자가 한글이 아님 → 공백, "서\n짧": 앞 줄이 가득 참 → 이어 붙임, "줄\n다": 앞 줄이 짧음 → 공백
        let tree = NSMaxRange(lines[1].range)
        #expect(LineJoiner.softBreaks(page: page, paragraphs: [paragraph], style: .characterWrap) == [tree])
    }
}
