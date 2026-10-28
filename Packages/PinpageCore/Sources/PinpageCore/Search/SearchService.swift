import Foundation
import GRDB

/// 검색 결과 하나.
public struct SearchHit: Equatable, Sendable, Identifiable {
    public let chunk: Chunk
    public let document: Document
    /// 1부터 시작하는 순위
    public let rank: Int
    public let bm25: Double
    /// 임베딩 코사인 유사도. 임베딩을 쓰지 않았으면 nil.
    public let semantic: Double?
    /// 정규화한 두 점수를 가중 합산한 최종 점수 (0~1)
    public let score: Double

    public var id: Int64 { chunk.id ?? -1 }
}

public struct SearchResult: Sendable {
    public let hits: [SearchHit]
    /// 임베딩 검색을 함께 썼는지. false면 BM25만 썼다.
    public let usedEmbedding: Bool
    /// 임베딩을 쓰지 못한 이유 (설정에서 꺼짐, 색인이 다른 모델로 만들어짐 등)
    public let embeddingUnavailableReason: String?
}

/// 두 점수를 질문마다 0~1로 정규화해 가중 합산한다.
public enum HybridScorer {
    /// - Parameter weight: 임베딩 점수 비중 (0이면 BM25만, 1이면 임베딩만)
    public static func combine(bm25: [Int64: Double], semantic: [Int64: Double]?, weight: Double) -> [Int64: Double] {
        let lexical = normalize(bm25)
        guard let semantic else { return lexical }
        let dense = normalize(semantic)
        var result: [Int64: Double] = [:]
        for id in Set(lexical.keys).union(dense.keys) {
            result[id] = weight * (dense[id] ?? 0) + (1 - weight) * (lexical[id] ?? 0)
        }
        return result
    }

    /// 최소-최대 정규화. 모든 값이 같으면(예: 질문 단어가 하나도 없음) 0.
    static func normalize(_ scores: [Int64: Double]) -> [Int64: Double] {
        guard let lo = scores.values.min(), let hi = scores.values.max(), hi > lo else {
            return scores.mapValues { _ in 0 }
        }
        return scores.mapValues { ($0 - lo) / (hi - lo) }
    }

    /// 점수 내림차순, 같으면 청크 ID 오름차순 (항상 같은 순서).
    static func ranked(_ scores: [Int64: Double]) -> [(id: Int64, score: Double)] {
        scores.map { ($0.key, $0.value) }.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0 < b.0
        }
    }
}

/// 학습 세트 안에서 하이브리드 검색을 한다. 세트별 BM25 색인과 벡터를 메모리에 캐시한다.
public actor SearchService {
    private let database: AppDatabase
    private var cache: [String: SetCache] = [:]

    private struct SetCache {
        let signature: String
        let chunks: [Int64: Chunk]
        let documents: [String: Document]
        let bm25: BM25Index
        let embedderKey: String?
        let vectors: [Int64: [Float]]
    }

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 세트의 색인이 바뀌었을 때 부른다.
    public func invalidate(setId: String) {
        cache[setId] = nil
    }

    public func search(
        setId: String,
        query: String,
        topK: Int,
        embedder: (any Embedder)?,
        prompts: EmbeddingPrompts?,
        embeddingWeight: Double
    ) async throws -> SearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResult(hits: [], usedEmbedding: false, embeddingUnavailableReason: nil) }

        let data = try load(setId: setId, embedderKey: embedder?.key)
        let bm25 = data.bm25.scores(for: trimmed)

        var semantic: [Int64: Double]?
        var reason: String?
        if let embedder, let prompts {
            if data.chunks.isEmpty {
                reason = nil
            } else if data.vectors.count == data.chunks.count {
                let queryVector = try await embedder.embed([prompts.renderQuery(trimmed)])[0]
                semantic = data.vectors.mapValues { Double(VectorMath.dot($0, queryVector)) }
            } else {
                reason = "현재 임베딩 설정으로 색인되지 않은 자료가 있어 키워드 검색(BM25)만 사용했습니다. 세트를 다시 색인하세요."
            }
        } else {
            reason = "임베딩이 꺼져 있어 키워드 검색(BM25)만 사용했습니다."
        }

        let combined = HybridScorer.combine(bm25: bm25, semantic: semantic, weight: semantic == nil ? 0 : embeddingWeight)
        let hits = HybridScorer.ranked(combined).prefix(topK).enumerated().compactMap { index, item -> SearchHit? in
            guard let chunk = data.chunks[item.id], let document = data.documents[chunk.documentId] else { return nil }
            return SearchHit(chunk: chunk, document: document, rank: index + 1,
                             bm25: bm25[item.id] ?? 0, semantic: semantic?[item.id], score: item.score)
        }
        return SearchResult(hits: hits, usedEmbedding: semantic != nil, embeddingUnavailableReason: reason)
    }

    private func load(setId: String, embedderKey: String?) throws -> SetCache {
        let signature = try database.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT COUNT(c.id) || ':' || IFNULL(MAX(c.id), 0) || ':' || IFNULL(MAX(d.indexedAt), '')
                FROM document d LEFT JOIN chunk c ON c.documentId = d.id WHERE d.setId = ?
                """, arguments: [setId]) ?? ""
        }
        if let cached = cache[setId], cached.signature == signature, cached.embedderKey == embedderKey {
            return cached
        }
        let loaded = try database.writer.read { db -> SetCache in
            let documents = try Document.filter(Column("setId") == setId && Column("status") == DocumentStatus.indexed.rawValue).fetchAll(db)
            let ids = documents.map(\.id)
            let chunks = try Chunk.filter(ids.contains(Column("documentId"))).fetchAll(db)
            var vectors: [Int64: [Float]] = [:]
            if let embedderKey {
                let rows = try ChunkEmbedding.fetchAll(db, sql: """
                    SELECT e.* FROM chunkEmbedding e JOIN chunk c ON c.id = e.chunkId
                    JOIN document d ON d.id = c.documentId
                    WHERE d.setId = ? AND d.status = 'indexed' AND e.embedderKey = ?
                    """, arguments: [setId, embedderKey])
                for row in rows { vectors[row.chunkId] = row.floats }
            }
            return SetCache(
                signature: signature,
                chunks: Dictionary(uniqueKeysWithValues: chunks.compactMap { c in c.id.map { ($0, c) } }),
                documents: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) }),
                bm25: BM25Index(documents: chunks.compactMap { c in c.id.map { ($0, c.text) } }),
                embedderKey: embedderKey,
                vectors: vectors
            )
        }
        cache[setId] = loaded
        return loaded
    }
}
