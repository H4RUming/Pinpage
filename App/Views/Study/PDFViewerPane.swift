import AppKit
import PDFKit
import PinpageCore
import SwiftUI

/// 근거 위치를 보여주는 PDF 뷰어. 해당 쪽으로 이동해 인용 문장(없으면 청크 영역)을 강조한다.
struct PDFViewerPane: View {
    let target: ViewerTarget?

    var body: some View {
        if let target {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "doc.text")
                    Text("\(target.fileName) · \(target.pageIndex + 1)쪽")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                PDFKitView(target: target)
            }
        } else {
            ContentUnavailableView("근거를 누르면 자료가 열립니다", systemImage: "doc.text.magnifyingglass",
                                   description: Text("답변과 힌트 아래의 근거 위치를 누르면 해당 쪽으로 이동해 강조합니다."))
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let target: ViewerTarget

    final class Coordinator {
        var documentURL: URL?
        var token: UUID?
        var annotations: [(PDFPage, PDFAnnotation)] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.documentURL != target.documentURL {
            view.document = PDFDocument(url: target.documentURL)
            coordinator.documentURL = target.documentURL
            coordinator.annotations = []
        }
        guard coordinator.token != target.token, let document = view.document,
              let page = document.page(at: target.pageIndex) else { return }
        coordinator.token = target.token

        // 이전 강조 지우기
        view.highlightedSelections = nil
        for (page, annotation) in coordinator.annotations { page.removeAnnotation(annotation) }
        coordinator.annotations = []

        let color = NSColor.systemYellow.withAlphaComponent(0.45)
        let selections = selections(on: page)
        if let first = selections.first {
            for selection in selections { selection.color = color }
            view.highlightedSelections = selections
            view.go(to: first)
            return
        }
        // OCR 페이지 등: 청크 영역에 강조 표시
        for rect in target.rects {
            let annotation = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .highlight, withProperties: nil)
            annotation.color = color
            page.addAnnotation(annotation)
            coordinator.annotations.append((page, annotation))
        }
        if let first = target.rects.first {
            view.go(to: first, on: page)
        } else {
            view.go(to: page)
        }
    }

    /// 인용 문장들의 선택 영역. 하나도 찾지 못하면 청크 전체, 텍스트 범위가 없으면(OCR) 빈 배열.
    private func selections(on page: PDFPage) -> [PDFSelection] {
        guard let chunkRange = target.chunkRange, let text = page.string else { return [] }
        let found = target.quotes.compactMap { quote in
            HighlightLocator.range(of: quote, in: text, within: chunkRange).flatMap { page.selection(for: $0) }
        }
        if !found.isEmpty { return found }
        return page.selection(for: chunkRange).map { [$0] } ?? []
    }
}
