import Foundation
import GRDB
import Testing
@testable import PinpageCore

/// 글자 바이그램을 해시해 만드는 결정적 가짜 임베딩 (모델 없이 하이브리드 검색 흐름을 확인한다).
struct FakeEmbedder: Embedder {
    let key: String
    var dimension = 64

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var v = [Float](repeating: 0, count: dimension)
            for token in BM25Tokenizer.tokens(text) {
                var h: UInt64 = 1469598103934665603
                for b in token.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                v[Int(h % UInt64(dimension))] += 1
            }
            return VectorMath.normalized(v)
        }
    }
}

private let prompts = EmbeddingPrompts(query: "task: search result | query: {text}", document: "title: {title} | text: {text}")
private let options = IndexingOptions(chunkSize: 300, chunkOverlap: 50, minChunkLength: 30, ocrLanguages: ["ko-KR", "en-US"], prompts: prompts)

private func makeLibrary() throws -> Library {
    let root = FileManager.default.temporaryDirectory.appending(path: "pinpage-lib-\(UUID().uuidString)")
    return Library(database: try AppDatabase.inMemory(), filesRoot: root)
}

@Suite("학습 세트와 문서")
struct LibraryTests {
    @Test("세트 만들기, 이름 바꾸기, 지우기")
    func sets() throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "  자료구조  ")
        #expect(set.name == "자료구조")
        try library.renameSet(id: set.id, to: "알고리즘")
        #expect(try library.sets().map(\.name) == ["알고리즘"])
        #expect(throws: LibraryError.emptyName) { try library.createSet(name: "   ") }
        try library.deleteSet(id: set.id)
        #expect(try library.sets().isEmpty)
    }

    @Test("PDF를 복사해 넣고, 같은 파일은 거부하고, 세트를 지우면 파일도 지운다")
    func importPDF() throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "운영체제")
        let pdf = try TestPDF.make(pages: [["교착 상태는 서로 자원을 기다리며 멈춘 상태다."]])
        defer { try? FileManager.default.removeItem(at: pdf) }

        let document = try library.importPDF(from: pdf, into: set.id)
        #expect(document.pageCount == 1)
        #expect(document.status == .pending)
        #expect(document.sha256.count == 64)
        #expect(FileManager.default.fileExists(atPath: library.fileURL(for: document).path))
        #expect(throws: LibraryError.duplicate(pdf.lastPathComponent)) { try library.importPDF(from: pdf, into: set.id) }

        let notPDF = FileManager.default.temporaryDirectory.appending(path: "not-\(UUID().uuidString).pdf")
        try Data("hello".utf8).write(to: notPDF)
        #expect(throws: LibraryError.notPDF(notPDF.lastPathComponent)) { try library.importPDF(from: notPDF, into: set.id) }

        try library.deleteSet(id: set.id)
        #expect(!FileManager.default.fileExists(atPath: library.fileURL(for: document).path))
    }

    @Test("DB가 위치 없는 청크를 거부한다")
    func chunkConstraints() throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "s")
        let pdf = try TestPDF.make(pages: [["내용"]])
        let document = try library.importPDF(from: pdf, into: set.id)
        try library.database.writer.write { db in
            #expect(throws: (any Error).self) {
                try db.execute(sql: "INSERT INTO chunk (documentId, ordinal, pageIndex, paragraphStart, paragraphEnd, rects, source, text) VALUES (?, 0, NULL, 0, 0, '[]', 'text', 'x')", arguments: [document.id])
            }
            #expect(throws: (any Error).self) {
                try db.execute(sql: "INSERT INTO chunk (documentId, ordinal, pageIndex, paragraphStart, paragraphEnd, rects, source, text) VALUES (?, 0, 0, 3, 1, '[]', 'text', 'x')", arguments: [document.id])
            }
            #expect(throws: (any Error).self) {
                try db.execute(sql: "INSERT INTO chunk (documentId, ordinal, pageIndex, paragraphStart, paragraphEnd, charStart, rects, source, text) VALUES (?, 0, 0, 0, 0, 5, '[]', 'text', 'x')", arguments: [document.id])
            }
            #expect(throws: (any Error).self) {
                try db.execute(sql: "INSERT INTO chunk (documentId, ordinal, pageIndex, paragraphStart, paragraphEnd, rects, source, text) VALUES ('없는문서', 0, 0, 0, 0, '[]', 'text', 'x')")
            }
        }
    }

    @Test("색인 도중 종료돼 남은 '색인 중' 문서를 '색인 대기'로 되돌린다")
    func resetInterrupted() throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "s")
        let document = try library.importPDF(from: try TestPDF.make(pages: [["내용"]]), into: set.id)
        try library.database.writer.write { db in
            try db.execute(sql: "UPDATE document SET status = 'indexing' WHERE id = ?", arguments: [document.id])
        }
        #expect(try library.resetInterruptedIndexing() == 1)
        #expect(try library.document(id: document.id)?.status == .pending)
        #expect(try library.resetInterruptedIndexing() == 0)
    }

    @Test("파일 DB는 WAL 모드로 연다")
    func walMode() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pinpage-\(UUID().uuidString)/pinpage.sqlite")
        let database = try AppDatabase.open(at: url)
        let mode = try database.writer.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }
}

@Suite("색인과 하이브리드 검색")
struct IndexAndSearchTests {
    @Test("PDF를 넣고 질문하면 관련 청크와 페이지를 돌려준다 (M2 완료 기준)")
    func endToEnd() async throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "CS 기초")
        let pdf = try TestPDF.make(pages: [
            ["파이썬의 리스트는 순서가 있는 가변 자료형이다. append로 원소를 추가한다.",
             "튜플은 한 번 만들면 원소를 바꿀 수 없는 불변 자료형이다."],
            ["교착 상태는 둘 이상의 프로세스가 서로 상대의 자원을 기다리며 영원히 멈춘 상태다.",
             "경쟁 상태는 여러 스레드가 공유 데이터에 동시에 접근할 때 생기는 문제다."],
            ["TCP는 연결을 맺고 데이터를 순서대로 빠짐없이 전달하는 프로토콜이다."],
        ], imageOnlyPages: [2])
        defer { try? FileManager.default.removeItem(at: pdf) }
        let document = try library.importPDF(from: pdf, into: set.id)

        let embedder = FakeEmbedder(key: "fake-v1")
        let indexer = DocumentIndexer(library: library)
        let phases = PhaseRecorder()
        try await indexer.index(documentId: document.id, options: options, embedder: embedder) { p in phases.add(p.phase) }

        let indexed = try #require(try library.document(id: document.id))
        #expect(indexed.status == .indexed)
        #expect(indexed.ocrPageCount == 1)
        #expect(indexed.ocrSystemVersion != nil)
        #expect(indexed.indexedEmbedderKey == "fake-v1")
        #expect(DocumentIndexer.isUpToDate(indexed, options: options, embedderKey: "fake-v1"))
        #expect(!DocumentIndexer.isUpToDate(indexed, options: options, embedderKey: "other"))
        var changed = options; changed.chunkSize = 500
        #expect(!DocumentIndexer.isUpToDate(indexed, options: changed, embedderKey: "fake-v1"))
        changed = options; changed.minChunkLength = 10
        #expect(!DocumentIndexer.isUpToDate(indexed, options: changed, embedderKey: "fake-v1"))
        // 문단 단위 청크: 2쪽의 두 문단이 따로 청크가 된다.
        let page2Chunks = try await library.database.writer.read { db in
            try Chunk.filter(Column("pageIndex") == 1).order(Column("ordinal")).fetchAll(db)
        }
        #expect(page2Chunks.map(\.paragraphStart) == [0, 1])
        #expect(phases.sawReading && phases.sawEmbedding)

        let chunks = try await library.database.writer.read { db in try Chunk.fetchAll(db) }
        #expect(!chunks.isEmpty)
        #expect(Set(chunks.map(\.pageIndex)) == [0, 1, 2])
        #expect(chunks.allSatisfy { !$0.rects.isEmpty })
        #expect(chunks.filter { $0.pageIndex == 2 }.allSatisfy { $0.source == .ocr && $0.charStart == nil })
        #expect(chunks.filter { $0.pageIndex < 2 }.allSatisfy { $0.source == .text && $0.charStart != nil })
        let embeddingCount = try await library.database.writer.read { db in try ChunkEmbedding.fetchCount(db) }
        #expect(embeddingCount == chunks.count)

        let search = SearchService(database: library.database)
        let deadlock = try await search.search(setId: set.id, query: "데드락이 생기는 조건", topK: 3,
                                               embedder: embedder, prompts: prompts, embeddingWeight: 0.5)
        #expect(deadlock.usedEmbedding)
        let top = try #require(deadlock.hits.first)
        #expect(top.chunk.pageIndex == 1)
        #expect(top.document.fileName == pdf.lastPathComponent)
        #expect(top.rank == 1 && top.semantic != nil && top.bm25 > 0)
        #expect(deadlock.hits.count <= 3)

        // OCR 페이지에서도 찾는다.
        let tcp = try await search.search(setId: set.id, query: "TCP 프로토콜", topK: 3, embedder: nil, prompts: nil, embeddingWeight: 0.5)
        #expect(!tcp.usedEmbedding)
        #expect(tcp.embeddingUnavailableReason != nil)
        #expect(tcp.hits.first?.chunk.pageIndex == 2)
    }

    @Test("다른 임베딩 설정으로 색인된 세트는 BM25만 쓰고 이유를 알려준다")
    func mismatchedEmbedder() async throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "s")
        let pdf = try TestPDF.make(pages: [["리스트는 가변 자료형이다."]])
        let document = try library.importPDF(from: pdf, into: set.id)
        try await DocumentIndexer(library: library).index(documentId: document.id, options: options, embedder: FakeEmbedder(key: "old"))

        let result = try await SearchService(database: library.database).search(
            setId: set.id, query: "리스트", topK: 5, embedder: FakeEmbedder(key: "new"), prompts: prompts, embeddingWeight: 0.5)
        #expect(!result.usedEmbedding)
        #expect(result.embeddingUnavailableReason?.contains("다시 색인") == true)
        #expect(result.hits.count == 1)
    }

    @Test("다시 색인하면 청크를 새로 만들고 검색 캐시도 갱신된다")
    func reindex() async throws {
        let library = try makeLibrary()
        let set = try library.createSet(name: "s")
        let long = String(repeating: "경쟁 상태는 실행 순서에 따라 결과가 달라지는 문제다. ", count: 12)
        let pdf = try TestPDF.make(pages: [[long]])
        let document = try library.importPDF(from: pdf, into: set.id)
        let indexer = DocumentIndexer(library: library)
        let search = SearchService(database: library.database)

        try await indexer.index(documentId: document.id, options: options, embedder: nil)
        let first = try library.documents(inSet: set.id)[0].chunkCount
        _ = try await search.search(setId: set.id, query: "경쟁", topK: 50, embedder: nil, prompts: nil, embeddingWeight: 0)

        var bigger = options; bigger.chunkSize = 2000; bigger.chunkOverlap = 0; bigger.minChunkLength = 0
        try await indexer.index(documentId: document.id, options: bigger, embedder: nil)
        let second = try library.documents(inSet: set.id)[0].chunkCount
        #expect(first > second)
        let hits = try await search.search(setId: set.id, query: "경쟁", topK: 50, embedder: nil, prompts: nil, embeddingWeight: 0).hits
        #expect(hits.count == second)
        #expect(Set(hits.map(\.chunk.ordinal)) == Set(0..<second))
    }
}

/// 색인 진행 단계를 기록한다.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [IndexingProgress.Phase] = []
    func add(_ p: IndexingProgress.Phase) { lock.withLock { phases.append(p) } }
    var sawReading: Bool { lock.withLock { phases.contains { if case .reading = $0 { true } else { false } } } }
    var sawEmbedding: Bool { lock.withLock { phases.contains { if case .embedding = $0 { true } else { false } } } }
}

@Suite("BM25")
struct BM25Tests {
    @Test("한글은 음절 2개씩, 영문은 단어, 그 밖은 한 글자씩")
    func tokenize() {
        #expect(BM25Tokenizer.tokens("리스트와") == ["리스", "스트", "트와"])
        #expect(BM25Tokenizer.tokens("값 binary_search(arr)") == ["값", "binary", "search", "arr"])
        #expect(BM25Tokenizer.tokens("TCP/IP 3방향") == ["tcp", "ip", "3", "방향"])
        #expect(BM25Tokenizer.tokens("漢字") == ["漢", "字"])
        #expect(BM25Tokenizer.tokens("ＡＢＣ①") == ["abc1"])  // 호환 문자 정규화
        #expect(BM25Tokenizer.tokens("…!?").isEmpty)
    }

    @Test("조사가 붙어도 찾고, 관련 문서가 위로 온다")
    func ranking() {
        let index = BM25Index(documents: [
            (1, "튜플은 불변 자료형이다"),
            (2, "리스트는 가변 자료형이다. 리스트에 append로 추가한다"),
            (3, "교착 상태는 자원을 기다리는 상태다"),
        ])
        let scores = index.scores(for: "리스트를 쓰는 법")
        #expect(scores[2]! > scores[1]!)
        #expect(scores[3] == 0)
        #expect(index.scores(for: "없는단어xyz").values.allSatisfy { $0 == 0 })
    }
}

@Suite("점수 합치기")
struct HybridScorerTests {
    @Test("정규화 후 가중 합산")
    func combine() {
        let bm25: [Int64: Double] = [1: 10, 2: 5, 3: 0]
        let semantic: [Int64: Double] = [1: 0.2, 2: 0.9, 3: 0.4]
        let onlyBM25 = HybridScorer.combine(bm25: bm25, semantic: semantic, weight: 0)
        #expect(onlyBM25 == [1: 1, 2: 0.5, 3: 0])
        let onlyEmbedding = HybridScorer.combine(bm25: bm25, semantic: semantic, weight: 1)
        #expect(abs(onlyEmbedding[2]! - 1) < 1e-9 && abs(onlyEmbedding[1]!) < 1e-9)
        let half = HybridScorer.combine(bm25: bm25, semantic: semantic, weight: 0.5)
        #expect(HybridScorer.ranked(half).map(\.id) == [2, 1, 3])
        #expect(HybridScorer.combine(bm25: bm25, semantic: nil, weight: 0.5) == onlyBM25)
    }

    @Test("점수가 모두 같으면 0, 순위는 청크 ID 순서로 항상 같다")
    func ties() {
        #expect(HybridScorer.normalize([1: 3, 2: 3]) == [1: 0, 2: 0])
        #expect(HybridScorer.ranked([5: 0.5, 2: 0.5, 9: 0.7]).map(\.id) == [9, 2, 5])
    }
}
