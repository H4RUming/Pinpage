import Foundation
@testable import PinpageCore

/// 임베딩 모델이 필요한 테스트용 도우미.
/// 모델 폴더: 환경 변수 PINPAGE_EMBEDDING_MODEL_DIR, 없으면 저장소의 dist/embedding-model.
/// 폴더가 없으면 해당 테스트는 건너뛴다 (`python3 Tools/prepare_embedding_model.py dist/embedding-model`로 만든다).
enum EmbeddingModelFixture {
    static let modelDirectory: URL? = {
        if let path = ProcessInfo.processInfo.environment["PINPAGE_EMBEDDING_MODEL_DIR"] {
            return URL(filePath: path)
        }
        // .../Packages/PinpageCore/Tests/PinpageCoreTests/이 파일 → 저장소 루트
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = repoRoot.appending(path: "dist/embedding-model")
        return FileManager.default.fileExists(atPath: dir.appending(path: "tokenizer.json").path) ? dir : nil
    }()

    static var isAvailable: Bool { modelDirectory != nil }

    struct GoldenCase: Decodable {
        let text: String
        let ids: [Int32]
        let vector: [Float]
    }

    static let golden: [GoldenCase] = {
        struct File: Decodable { let cases: [GoldenCase] }
        let url = Bundle.module.url(forResource: "embedding_golden", withExtension: "json", subdirectory: "Resources")!
        return try! JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }()

    /// 토크나이저는 크게 한 번만 읽는다 (32MB JSON).
    static let tokenizer: GemmaTokenizer? = modelDirectory.flatMap {
        try? GemmaTokenizer(contentsOf: $0.appending(path: "tokenizer.json"))
    }
}
