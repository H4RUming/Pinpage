import AppKit
import PDFKit
import PinpageCore
import SwiftUI

/// 학습 자료 뷰어: 문서 고르기, 쪽 표시, 문서 안 찾기(⌘F). 도구·대조 조건이 같은 뷰어를 쓴다.
/// 근거 위치(`target`)가 바뀌면 그 문서와 쪽으로 이동해 인용 문장(없으면 청크 영역)을 강조한다.
struct MaterialsView: View {
    let documents: [PinpageCore.Document]
    let library: Library
    let target: ViewerTarget?
    let logger: EventLogger?

    @State private var controller = PDFController()
    @State private var selectedId: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if documents.isEmpty {
                ContentUnavailableView("자료가 없습니다", systemImage: "doc.text",
                                       description: Text("학습 세트에 PDF를 넣고 색인하면 여기에서 볼 수 있습니다."))
            } else {
                PDFKitView(controller: controller)
            }
        }
        .onAppear { selectInitial() }
        .onChange(of: documents.map(\.id)) { selectInitial() }
        .onChange(of: selectedId) { _, id in openSelected(id) }
        .onChange(of: target?.token) { showTarget() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("자료", selection: $selectedId) {
                ForEach(documents) { document in
                    Text(document.fileName).tag(Optional(document.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            if controller.pageCount > 0 {
                Text("\(controller.pageIndex + 1) / \(controller.pageCount)쪽")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("문서에서 찾기", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($searchFocused)
                .onSubmit { find() }
            if let searched = controller.searchedQuery, searched == query.trimmingCharacters(in: .whitespacesAndNewlines) {
                if controller.matchCount > 0 {
                    Text("\(controller.matchIndex + 1)/\(controller.matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { controller.moveMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                        .help("이전 찾은 곳")
                    Button { controller.moveMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                        .help("다음 찾은 곳")
                } else {
                    Text("없음").font(.caption).foregroundStyle(.secondary)
                }
            }
            // ⌘F로 찾기 칸에 들어간다.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func selectInitial() {
        if let target, let document = documents.first(where: { library.fileURL(for: $0) == target.documentURL }) {
            selectedId = document.id
        } else if selectedId == nil || !documents.contains(where: { $0.id == selectedId }) {
            selectedId = documents.first?.id
        }
    }

    private func openSelected(_ id: String?) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        let url = library.fileURL(for: document)
        guard controller.documentURL != url else { return }
        controller.open(url)
        query = ""
        let viaCitation = target?.documentURL == url
        logger?.log(.documentOpened, DocumentOpenedPayload(document: document, via: viaCitation ? "citation" : "list"))
    }

    private func showTarget() {
        guard let target else { return }
        if let document = documents.first(where: { library.fileURL(for: $0) == target.documentURL }), selectedId != document.id {
            selectedId = document.id
            openSelected(document.id)
        }
        controller.show(target)
    }

    private func find() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let document = documents.first(where: { $0.id == selectedId }) else { return }
        let count = controller.find(text)
        logger?.log(.documentSearched, DocumentSearchedPayload(document: document, query: text, matchCount: count))
    }
}

/// PDFView를 직접 다룬다 (문서 열기, 근거 강조, 찾기, 쪽 번호).
@Observable @MainActor
final class PDFController {
    private(set) var documentURL: URL?
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var searchedQuery: String?
    private(set) var matchCount = 0
    private(set) var matchIndex = 0

    @ObservationIgnored private weak var view: PDFView?
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var annotations: [(PDFPage, PDFAnnotation)] = []
    @ObservationIgnored private var pendingTarget: ViewerTarget?
    @ObservationIgnored private var pageObserver: NSObjectProtocol?

    private let highlightColor = NSColor.systemYellow.withAlphaComponent(0.45)
    private let matchColor = NSColor.systemOrange.withAlphaComponent(0.5)

    func attach(_ view: PDFView) {
        self.view = view
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
        if let url = documentURL { load(url) }
        if let pending = pendingTarget {
            pendingTarget = nil
            show(pending)
        }
    }

    func open(_ url: URL) {
        documentURL = url
        load(url)
    }

    private func load(_ url: URL) {
        guard let view else { return }
        if view.document?.documentURL != url {
            clearHighlights()
            view.document = PDFDocument(url: url)
        }
        clearSearch()
        updatePage()
    }

    /// 근거 위치로 이동해 강조한다.
    func show(_ target: ViewerTarget) {
        guard let view else { pendingTarget = target; return }
        if documentURL != target.documentURL { open(target.documentURL) }
        guard let page = view.document?.page(at: target.pageIndex) else { return }
        clearHighlights()
        clearSearch()

        let selections = selections(for: target, on: page)
        if let first = selections.first {
            for selection in selections { selection.color = highlightColor }
            view.highlightedSelections = selections
            view.go(to: first)
            return
        }
        // OCR 페이지 등: 청크 영역에 강조 표시
        for rect in target.rects {
            let annotation = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .highlight, withProperties: nil)
            annotation.color = highlightColor
            page.addAnnotation(annotation)
            annotations.append((page, annotation))
        }
        if let first = target.rects.first {
            view.go(to: first, on: page)
        } else {
            view.go(to: page)
        }
    }

    /// 문서 전체에서 찾고, 찾은 개수를 돌려준다.
    @discardableResult
    func find(_ query: String) -> Int {
        guard let view, let document = view.document else { return 0 }
        clearHighlights()
        matches = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = matchColor }
        searchedQuery = query
        matchCount = matches.count
        matchIndex = 0
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if let first = matches.first { view.go(to: first) }
        return matches.count
    }

    func moveMatch(by step: Int) {
        guard let view, !matches.isEmpty else { return }
        matchIndex = (matchIndex + step + matches.count) % matches.count
        view.go(to: matches[matchIndex])
    }

    private func clearHighlights() {
        view?.highlightedSelections = nil
        for (page, annotation) in annotations { page.removeAnnotation(annotation) }
        annotations = []
    }

    private func clearSearch() {
        matches = []
        searchedQuery = nil
        matchCount = 0
        matchIndex = 0
    }

    private func updatePage() {
        guard let view, let document = view.document else {
            pageCount = 0
            return
        }
        pageCount = document.pageCount
        if let page = view.currentPage { pageIndex = document.index(for: page) }
    }

    /// 인용 문장들의 선택 영역. 하나도 찾지 못하면 청크 전체, 텍스트 범위가 없으면(OCR) 빈 배열.
    private func selections(for target: ViewerTarget, on page: PDFPage) -> [PDFSelection] {
        guard let chunkRange = target.chunkRange, let text = page.string else { return [] }
        let found = target.quotes.compactMap { quote in
            HighlightLocator.range(of: quote, in: text, within: chunkRange).flatMap { page.selection(for: $0) }
        }
        if !found.isEmpty { return found }
        return page.selection(for: chunkRange).map { [$0] } ?? []
    }
}

private struct PDFKitView: NSViewRepresentable {
    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        controller.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
