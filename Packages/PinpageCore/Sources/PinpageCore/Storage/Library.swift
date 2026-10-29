import CryptoKit
import Foundation
import GRDB
import PDFKit

/// 학습 세트와 자료 파일을 관리한다.
/// 자료 파일은 앱 데이터 폴더로 복사해 두므로 원래 위치의 파일이 옮겨져도 깨지지 않는다.
public struct Library: Sendable {
    public let database: AppDatabase
    /// 자료 파일을 두는 폴더 (`Application Support/Pinpage/sets`)
    public let filesRoot: URL

    public init(database: AppDatabase, filesRoot: URL) {
        self.database = database
        self.filesRoot = filesRoot
    }

    public struct DocumentSummary: Equatable, Sendable, Identifiable {
        public let document: Document
        public let chunkCount: Int
        public var id: String { document.id }
    }

    // MARK: - 학습 세트

    public func sets() throws -> [LearningSet] {
        try database.writer.read { db in
            try LearningSet.order(Column("createdAt"), Column("name")).fetchAll(db)
        }
    }

    @discardableResult
    public func createSet(name: String) throws -> LearningSet {
        let set = LearningSet(name: try Self.validName(name))
        try database.writer.write { db in try set.insert(db) }
        return set
    }

    public func renameSet(id: String, to name: String) throws {
        let name = try Self.validName(name)
        try database.writer.write { db in
            guard var set = try LearningSet.fetchOne(db, key: id) else { throw LibraryError.setNotFound }
            set.name = name
            try set.update(db)
        }
    }

    /// 세트와 그 안의 문서, 청크, 임베딩, 복사해 둔 파일을 모두 지운다.
    public func deleteSet(id: String) throws {
        _ = try database.writer.write { db in try LearningSet.deleteOne(db, key: id) }
        try? FileManager.default.removeItem(at: filesRoot.appending(path: id))
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyName }
        return trimmed
    }

    // MARK: - 문서

    public func documents(inSet setId: String) throws -> [DocumentSummary] {
        try database.writer.read { db in
            let documents = try Document
                .filter(Column("setId") == setId)
                .order(Column("importedAt"), Column("fileName"))
                .fetchAll(db)
            let counts = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT documentId, COUNT(*) AS n FROM chunk
                WHERE documentId IN (SELECT id FROM document WHERE setId = ?)
                GROUP BY documentId
                """, arguments: [setId]).map { ($0["documentId"] as String, $0["n"] as Int) })
            return documents.map { DocumentSummary(document: $0, chunkCount: counts[$0.id] ?? 0) }
        }
    }

    public func document(id: String) throws -> Document? {
        try database.writer.read { db in try Document.fetchOne(db, key: id) }
    }

    public func fileURL(for document: Document) -> URL {
        filesRoot.appending(path: document.storedPath)
    }

    /// PDF를 세트에 추가한다 (아직 색인 전 상태). 같은 내용의 파일은 한 세트에 한 번만 넣을 수 있다.
    @discardableResult
    public func importPDF(from source: URL, into setId: String) throws -> Document {
        let data = try Data(contentsOf: source)
        guard let pdf = PDFDocument(data: data) else { throw LibraryError.notPDF(source.lastPathComponent) }
        guard !pdf.isLocked else { throw LibraryError.lockedPDF(source.lastPathComponent) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let id = UUID().uuidString
        let storedPath = "\(setId)/\(id).pdf"
        let document = Document(
            id: id, setId: setId, kind: .pdf, fileName: source.lastPathComponent, storedPath: storedPath,
            sha256: sha, pageCount: pdf.pageCount, status: .pending, errorMessage: nil,
            ocrPageCount: 0, ocrSystemVersion: nil, indexedChunkSize: nil, indexedChunkOverlap: nil, indexedMinChunkLength: nil,
            indexedEmbedderKey: nil, indexedAt: nil, importedAt: Date()
        )

        let destination = filesRoot.appending(path: storedPath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        do {
            try database.writer.write { db in
                guard try LearningSet.exists(db, key: setId) else { throw LibraryError.setNotFound }
                if try Document.filter(Column("setId") == setId && Column("sha256") == sha).fetchCount(db) > 0 {
                    throw LibraryError.duplicate(source.lastPathComponent)
                }
                try document.insert(db)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return document
    }

    /// 색인 도중 앱이 종료돼 "색인 중"으로 남은 문서를 "색인 대기"로 되돌린다. 앱을 켤 때 부른다.
    /// 앞서 만든 청크는 다음 색인 때 지우고 새로 만든다.
    @discardableResult
    public func resetInterruptedIndexing() throws -> Int {
        try database.writer.write { db in
            try Document
                .filter(Column("status") == DocumentStatus.indexing.rawValue)
                .updateAll(db, Column("status").set(to: DocumentStatus.pending.rawValue))
        }
    }

    public func deleteDocument(id: String) throws {
        guard let document = try document(id: id) else { return }
        _ = try database.writer.write { db in try Document.deleteOne(db, key: id) }
        try? FileManager.default.removeItem(at: fileURL(for: document))
    }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case emptyName
    case setNotFound
    case notPDF(String)
    case lockedPDF(String)
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "이름을 입력하세요."
        case .setNotFound: "학습 세트를 찾을 수 없습니다."
        case .notPDF(let name): "'\(name)'은(는) PDF로 읽을 수 없습니다."
        case .lockedPDF(let name): "'\(name)'은(는) 암호가 걸린 PDF라 읽을 수 없습니다."
        case .duplicate(let name): "'\(name)'과(와) 같은 내용의 파일이 이미 이 세트에 있습니다."
        }
    }
}
