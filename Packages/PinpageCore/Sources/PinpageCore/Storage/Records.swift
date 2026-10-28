import Foundation
import GRDB

/// 학습 세트. PDF와 코드 파일을 묶는 단위.
public struct LearningSet: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "learningSet"

    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public enum DocumentKind: String, Codable, Sendable {
    case pdf
    case code
}

public enum DocumentStatus: String, Codable, Sendable {
    case pending
    case indexing
    case indexed
    case failed
}

/// 학습 세트에 넣은 자료 파일 하나.
public struct Document: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "document"

    public var id: String
    public var setId: String
    public var kind: DocumentKind
    /// 사용자가 고른 원래 파일 이름.
    public var fileName: String
    /// 앱 데이터 폴더(`sets/`) 기준 상대 경로.
    public var storedPath: String
    public var sha256: String
    public var pageCount: Int
    public var status: DocumentStatus
    public var errorMessage: String?
    /// OCR로 읽은 페이지 수와 그때의 macOS 버전 (OCR 결과는 OS 버전에 따라 달라질 수 있다).
    public var ocrPageCount: Int
    public var ocrSystemVersion: String?
    /// 색인할 때 쓴 값. 현재 설정과 다르면 다시 색인해야 한다.
    public var indexedChunkSize: Int?
    public var indexedChunkOverlap: Int?
    public var indexedEmbedderKey: String?
    public var indexedAt: Date?
    public var importedAt: Date

    /// 확장자를 뺀 파일 이름 (임베딩 문서 제목으로 쓴다).
    public var title: String {
        (fileName as NSString).deletingPathExtension
    }
}

/// 자료에서 잘라낸 검색 단위. 반드시 출처 문서와 위치(페이지, 문단 범위)를 가진다.
public struct Chunk: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chunk"

    public var id: Int64?
    public var documentId: String
    /// 문서 안에서의 순번 (0부터).
    public var ordinal: Int
    /// 페이지 번호 (0부터). 화면에는 1을 더해 보여준다.
    public var pageIndex: Int
    /// 페이지 안의 문단 번호 범위 (0부터, 끝 포함).
    public var paragraphStart: Int
    public var paragraphEnd: Int
    /// 페이지 텍스트(PDFPage.string) 안의 UTF-16 범위. OCR 청크는 nil.
    public var charStart: Int?
    public var charEnd: Int?
    /// 강조 표시용 영역 (PDF 페이지 좌표, 줄 단위).
    public var rects: [PageRect]
    public var source: ChunkSource
    public var text: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum ChunkSource: String, Codable, Sendable {
    /// PDF에 들어 있는 텍스트
    case text
    /// 페이지 이미지를 OCR로 읽은 텍스트
    case ocr
}

/// PDF 페이지 좌표의 사각형 (원점은 페이지 왼쪽 아래).
public struct PageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// 청크 하나의 임베딩 벡터.
public struct ChunkEmbedding: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chunkEmbedding"

    public var chunkId: Int64
    public var embedderKey: String
    public var dimension: Int
    /// float32 리틀 엔디언
    public var vector: Data

    public init(chunkId: Int64, embedderKey: String, vector: [Float]) {
        self.chunkId = chunkId
        self.embedderKey = embedderKey
        self.dimension = vector.count
        self.vector = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public var floats: [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
