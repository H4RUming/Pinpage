import Foundation
import Observation
import PinpageCore

/// 학습 세트 화면의 상태: 세트 목록, 자료, 색인 진행, 검색 테스트.
@Observable @MainActor
final class LibraryModel {
    struct IndexingState: Equatable {
        var fileName: String
        var detail: String
        var fraction: Double
        var remaining: Int
    }

    private(set) var sets: [LearningSet] = []
    var selectedSetId: String? {
        didSet {
            guard selectedSetId != oldValue else { return }
            searchResult = nil
            searchError = nil
            reloadDocuments()
        }
    }
    private(set) var documents: [Library.DocumentSummary] = []
    private(set) var indexing: IndexingState?
    var errorMessage: String?

    var query = ""
    private(set) var searchResult: SearchResult?
    private(set) var searchError: String?
    private(set) var isSearching = false

    let library: Library
    private let indexer: DocumentIndexer
    private let search: SearchService
    private unowned let app: AppModel
    private var queue: [String] = []
    private var indexTask: Task<Void, Never>?

    init(library: Library, app: AppModel) {
        self.library = library
        self.indexer = DocumentIndexer(library: library)
        self.search = SearchService(database: library.database)
        self.app = app
        _ = try? library.resetInterruptedIndexing()
        reloadSets()
        selectedSetId = sets.first?.id
        reloadDocuments()
    }

    var selectedSet: LearningSet? { sets.first { $0.id == selectedSetId } }

    // MARK: - 세트

    func reloadSets() {
        do {
            sets = try library.sets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSet(name: String) {
        do {
            let set = try library.createSet(name: name)
            reloadSets()
            selectedSetId = set.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSet(id: String, to name: String) {
        do {
            try library.renameSet(id: id, to: name)
            reloadSets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSet(id: String) {
        guard indexing == nil else { errorMessage = "색인 중에는 세트를 지울 수 없습니다."; return }
        do {
            try library.deleteSet(id: id)
            Task { await search.invalidate(setId: id) }
            reloadSets()
            if selectedSetId == id { selectedSetId = sets.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 문서

    func reloadDocuments() {
        guard let setId = selectedSetId else { documents = []; return }
        do {
            documents = try library.documents(inSet: setId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var indexingOptions: IndexingOptions {
        let s = app.settings
        return IndexingOptions(chunkSize: s.retrieval.chunkSize, chunkOverlap: s.retrieval.chunkOverlap,
                               minChunkLength: s.retrieval.minChunkLength, ocrLanguages: s.retrieval.ocrLanguages, prompts: app.embeddingManager.prompts)
    }

    var currentEmbedderKey: String? { app.embeddingManager.embedderKey(for: app.settings) }

    func isUpToDate(_ document: Document) -> Bool {
        DocumentIndexer.isUpToDate(document, options: indexingOptions, embedderKey: currentEmbedderKey)
    }

    /// 현재 설정과 다르게 색인된(또는 색인 안 된) 자료.
    var outdatedDocuments: [Document] {
        documents.map(\.document).filter { !isUpToDate($0) && $0.status != .indexing }
    }

    func addPDFs(_ urls: [URL]) {
        guard let setId = selectedSetId else { return }
        var failures: [String] = []
        var added: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                added.append(try library.importPDF(from: url, into: setId).id)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        reloadDocuments()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        enqueue(added)
    }

    func deleteDocument(_ id: String) {
        guard indexing == nil else { errorMessage = "색인 중에는 자료를 지울 수 없습니다."; return }
        do {
            try library.deleteDocument(id: id)
            if let setId = selectedSetId { Task { await search.invalidate(setId: setId) } }
            reloadDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reindexOutdated() {
        enqueue(outdatedDocuments.map(\.id))
    }

    func reindex(_ id: String) {
        enqueue([id])
    }

    // MARK: - 색인

    /// 임베딩을 쓰도록 설정했는데 준비가 안 됐으면 색인하지 않는다 (나중에 다시 색인해야 하므로).
    var indexingBlockedReason: String? {
        let manager = app.embeddingManager
        if app.settings.embedding.mode != .off, manager.embedder == nil {
            return "임베딩 모델 준비가 끝나야 색인할 수 있습니다. 설정 탭에서 모델 상태를 확인하세요."
        }
        return nil
    }

    private func enqueue(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if let reason = indexingBlockedReason {
            errorMessage = reason
            return
        }
        for id in ids where !queue.contains(id) { queue.append(id) }
        guard indexTask == nil else { return }
        indexTask = Task { await runQueue() }
    }

    func cancelIndexing() {
        queue.removeAll()
        indexTask?.cancel()
    }

    private func runQueue() async {
        defer {
            indexTask = nil
            indexing = nil
            reloadDocuments()
        }
        while !queue.isEmpty, !Task.isCancelled {
            let id = queue.removeFirst()
            guard let document = try? library.document(id: id) else { continue }
            indexing = IndexingState(fileName: document.fileName, detail: "준비 중", fraction: 0, remaining: queue.count)
            reloadDocuments()
            do {
                try await indexer.index(documentId: id, options: indexingOptions, embedder: app.embeddingManager.embedder) { progress in
                    Task { @MainActor in self.show(progress) }
                }
            } catch is CancellationError {
                break
            } catch {
                errorMessage = "'\(document.fileName)' 색인 실패: \(error.localizedDescription)"
            }
            await search.invalidate(setId: document.setId)
        }
    }

    private func show(_ progress: IndexingProgress) {
        guard var state = indexing, state.fileName == progress.fileName else { return }
        switch progress.phase {
        case .reading(let page, let count, let ocr):
            state.detail = "\(page)/\(count)쪽 읽는 중" + (ocr ? " (OCR)" : "")
            state.fraction = Double(page) / Double(max(count, 1)) * 0.6
        case .embedding(let done, let count):
            state.detail = "임베딩 \(done)/\(count)"
            state.fraction = 0.6 + Double(done) / Double(max(count, 1)) * 0.4
        }
        state.remaining = queue.count
        indexing = state
    }

    // MARK: - 검색

    func runSearch() {
        guard let setId = selectedSetId else { return }
        let query = query
        let settings = app.settings
        let manager = app.embeddingManager
        isSearching = true
        searchError = nil
        Task {
            defer { isSearching = false }
            do {
                searchResult = try await search.search(
                    setId: setId, query: query, topK: settings.retrieval.topK,
                    embedder: manager.embedder, prompts: manager.prompts,
                    embeddingWeight: settings.retrieval.embeddingWeight
                )
            } catch let error as LLMRequestError {
                searchError = error.message
            } catch {
                searchError = error.localizedDescription
            }
        }
    }
}
