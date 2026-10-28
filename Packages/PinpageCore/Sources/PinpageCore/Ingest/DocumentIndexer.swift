import Foundation
import GRDB
import PDFKit

/// 색인할 때 쓰는 값. 설정에서 온다.
public struct IndexingOptions: Equatable, Sendable {
    public var chunkSize: Int
    public var chunkOverlap: Int
    public var ocrLanguages: [String]
    public var prompts: EmbeddingPrompts?

    public init(chunkSize: Int, chunkOverlap: Int, ocrLanguages: [String], prompts: EmbeddingPrompts?) {
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.ocrLanguages = ocrLanguages
        self.prompts = prompts
    }
}

public struct IndexingProgress: Sendable {
    public enum Phase: Sendable {
        case reading(page: Int, of: Int, ocr: Bool)
        case embedding(done: Int, of: Int)
    }
    public let documentId: String
    public let fileName: String
    public let phase: Phase
}

/// PDF를 읽어 청크로 나누고 임베딩까지 만들어 DB에 저장한다.
public struct DocumentIndexer: Sendable {
    public let library: Library
    public static let embeddingBatchSize = 8

    public init(library: Library) {
        self.library = library
    }

    /// 현재 설정으로 색인했는지 확인한다. 다르면 다시 색인해야 한다.
    public static func isUpToDate(_ document: Document, options: IndexingOptions, embedderKey: String?) -> Bool {
        document.status == .indexed
            && document.indexedChunkSize == options.chunkSize
            && document.indexedChunkOverlap == options.chunkOverlap
            && document.indexedEmbedderKey == embedderKey
    }

    public func index(
        documentId: String,
        options: IndexingOptions,
        embedder: (any Embedder)?,
        progress: (@Sendable (IndexingProgress) -> Void)? = nil
    ) async throws {
        guard let document = try library.document(id: documentId) else { throw LibraryError.setNotFound }
        try setStatus(documentId, .indexing, error: nil)
        do {
            try await run(document: document, options: options, embedder: embedder, progress: progress)
        } catch {
            try? setStatus(documentId, error is CancellationError ? .pending : .failed,
                           error: error is CancellationError ? nil : error.localizedDescription)
            throw error
        }
    }

    private func run(
        document: Document,
        options: IndexingOptions,
        embedder: (any Embedder)?,
        progress: (@Sendable (IndexingProgress) -> Void)?
    ) async throws {
        let url = library.fileURL(for: document)
        let pageContents = try await Self.extractPages(url: url, ocrLanguages: options.ocrLanguages) { page, count, ocr in
            progress?(IndexingProgress(documentId: document.id, fileName: document.fileName,
                                       phase: .reading(page: page, of: count, ocr: ocr)))
        }

        var drafts: [ChunkDraft] = []
        var sources: [ChunkSource] = []
        for content in pageContents {
            let paragraphs = ParagraphSegmenter.paragraphs(from: content.lines)
            let pageDrafts = Chunker.chunks(page: content, paragraphs: paragraphs,
                                            size: options.chunkSize, overlap: options.chunkOverlap)
            drafts += pageDrafts
            sources += Array(repeating: content.source, count: pageDrafts.count)
        }

        var vectors: [[Float]] = []
        if let embedder, let prompts = options.prompts {
            for start in stride(from: 0, to: drafts.count, by: Self.embeddingBatchSize) {
                try Task.checkCancellation()
                let batch = drafts[start..<min(start + Self.embeddingBatchSize, drafts.count)]
                vectors += try await embedder.embed(batch.map { prompts.renderDocument(title: document.title, text: $0.text) })
                progress?(IndexingProgress(documentId: document.id, fileName: document.fileName,
                                           phase: .embedding(done: min(start + Self.embeddingBatchSize, drafts.count), of: drafts.count)))
            }
        }
        try Task.checkCancellation()

        let ocrPages = pageContents.filter { $0.source == .ocr }.count
        let embedderKey = vectors.isEmpty ? nil : embedder?.key
        let finalDrafts = drafts, finalSources = sources, finalVectors = vectors
        try await library.database.writer.write { db in
            try Chunk.filter(Column("documentId") == document.id).deleteAll(db)
            for (ordinal, draft) in finalDrafts.enumerated() {
                var chunk = Chunk(
                    id: nil, documentId: document.id, ordinal: ordinal, pageIndex: draft.pageIndex,
                    paragraphStart: draft.paragraphStart, paragraphEnd: draft.paragraphEnd,
                    charStart: finalSources[ordinal] == .text ? draft.range.location : nil,
                    charEnd: finalSources[ordinal] == .text ? NSMaxRange(draft.range) : nil,
                    rects: draft.rects.map(PageRect.init), source: finalSources[ordinal], text: draft.text
                )
                try chunk.insert(db)
                if let embedderKey, let id = chunk.id {
                    try ChunkEmbedding(chunkId: id, embedderKey: embedderKey, vector: finalVectors[ordinal]).insert(db)
                }
            }
            guard var stored = try Document.fetchOne(db, key: document.id) else { return }
            stored.status = .indexed
            stored.errorMessage = nil
            stored.ocrPageCount = ocrPages
            stored.ocrSystemVersion = ocrPages > 0 ? ProcessInfo.processInfo.operatingSystemVersionString : nil
            stored.indexedChunkSize = options.chunkSize
            stored.indexedChunkOverlap = options.chunkOverlap
            stored.indexedEmbedderKey = embedderKey
            stored.indexedAt = Date()
            try stored.update(db)
        }
    }

    /// PDFKit 객체는 Sendable이 아니므로 이 함수 안에서만 쓴다.
    static func extractPages(
        url: URL,
        ocrLanguages: [String],
        onPage: (Int, Int, Bool) -> Void
    ) async throws -> [PageContent] {
        guard let pdf = PDFDocument(url: url) else { throw PDFExtractorError.cannotOpen }
        var contents: [PageContent] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            let ocr = PDFExtractor.needsOCR(page)
            onPage(index + 1, pdf.pageCount, ocr)
            contents.append(try await PDFExtractor.content(of: page, index: index, ocrLanguages: ocrLanguages))
        }
        return contents
    }

    private func setStatus(_ id: String, _ status: DocumentStatus, error: String?) throws {
        try library.database.writer.write { db in
            guard var document = try Document.fetchOne(db, key: id) else { return }
            document.status = status
            document.errorMessage = error
            try document.update(db)
        }
    }
}
