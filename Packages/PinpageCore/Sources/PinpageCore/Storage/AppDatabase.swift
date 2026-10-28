import Foundation
import GRDB

/// 앱의 로컬 SQLite DB. 파일: `Application Support/Pinpage/pinpage.sqlite` (WAL 모드)
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 파일 DB. DatabasePool은 WAL 모드를 쓴다 (강제 종료에도 커밋한 내용이 남는다).
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    /// 테스트용 메모리 DB.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1: 학습 세트, 문서, 청크, 임베딩") { db in
            try db.create(table: "learningSet") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "document") { t in
                t.primaryKey("id", .text)
                t.column("setId", .text).notNull().indexed()
                    .references("learningSet", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("storedPath", .text).notNull()
                t.column("sha256", .text).notNull()
                t.column("pageCount", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("errorMessage", .text)
                t.column("ocrPageCount", .integer).notNull().defaults(to: 0)
                t.column("ocrSystemVersion", .text)
                t.column("indexedChunkSize", .integer)
                t.column("indexedChunkOverlap", .integer)
                t.column("indexedEmbedderKey", .text)
                t.column("indexedAt", .datetime)
                t.column("importedAt", .datetime).notNull()
                t.uniqueKey(["setId", "sha256"])
            }

            // 모든 청크는 출처 문서와 위치(페이지, 문단 범위)를 반드시 가진다.
            try db.create(table: "chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("documentId", .text).notNull().indexed()
                    .references("document", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("pageIndex", .integer).notNull().check { $0 >= 0 }
                t.column("paragraphStart", .integer).notNull().check { $0 >= 0 }
                t.column("paragraphEnd", .integer).notNull()
                t.column("charStart", .integer)
                t.column("charEnd", .integer)
                t.column("rects", .text).notNull()
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.check(sql: "paragraphEnd >= paragraphStart")
                t.check(sql: "(charStart IS NULL) = (charEnd IS NULL)")
                t.check(sql: "charEnd IS NULL OR charEnd > charStart")
                t.uniqueKey(["documentId", "ordinal"])
            }

            try db.create(table: "chunkEmbedding") { t in
                t.column("chunkId", .integer).notNull()
                    .references("chunk", onDelete: .cascade)
                t.column("embedderKey", .text).notNull()
                t.column("dimension", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.primaryKey(["chunkId", "embedderKey"])
            }
        }

        return migrator
    }
}
