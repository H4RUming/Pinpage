import Foundation
import Testing
@testable import PinpageCore

/// 컴파일 결과는 테스트 실행 사이에 재사용한다 (dist 폴더는 건드리지 않는다).
private let compileCache = FileManager.default.temporaryDirectory.appending(path: "pinpage-test-coreml-cache")

@Suite("Core ML 임베더", .enabled(if: EmbeddingModelFixture.isAvailable, "임베딩 모델 폴더가 없음"), .serialized)
struct CoreMLEmbedderTests {
    private func embedder(_ unit: EmbeddingComputeUnit, dimension: Int = 768) async throws -> CoreMLEmbedder {
        try await CoreMLEmbedder(
            modelDirectory: try #require(EmbeddingModelFixture.modelDirectory),
            cacheDirectory: compileCache,
            computeUnit: unit,
            dimension: dimension,
            key: "test"
        )
    }

    @Test("GPU 결과가 PyTorch float32 기준값과 같다")
    func gpuMatchesReference() async throws {
        let embedder = try await embedder(.gpu)
        let golden = EmbeddingModelFixture.golden
        let vectors = try await embedder.embed(golden.map(\.text))
        for (vector, g) in zip(vectors, golden) {
            #expect(vector.count == 768)
            let cosine = VectorMath.dot(vector, g.vector)
            #expect(cosine > 0.9999, "cos=\(cosine) \(g.text.prefix(30))")
        }
    }

    @Test("Neural Engine 결과도 기준값과 거의 같다")
    func neuralEngineCloseToReference() async throws {
        let embedder = try await embedder(.neuralEngine)
        let golden = EmbeddingModelFixture.golden
        let vectors = try await embedder.embed(golden.map(\.text))
        for (vector, g) in zip(vectors, golden) {
            #expect(VectorMath.dot(vector, g.vector) > 0.999)
        }
    }

    @Test("차원을 줄이면 앞부분을 잘라 다시 정규화한다")
    func matryoshka() async throws {
        let embedder = try await embedder(.gpu, dimension: 256)
        let vector = try await embedder.embed([EmbeddingModelFixture.golden[0].text])[0]
        #expect(vector.count == 256)
        #expect(abs(VectorMath.dot(vector, vector) - 1) < 1e-4)
        let expected = VectorMath.normalized(Array(EmbeddingModelFixture.golden[0].vector.prefix(256)))
        #expect(VectorMath.dot(vector, expected) > 0.9999)
    }

    @Test("지원하지 않는 차원은 거부한다")
    func badDimension() async throws {
        await #expect(throws: CoreMLEmbedderError.self) { try await embedder(.gpu, dimension: 300) }
    }
}

@Suite("임베딩 프롬프트")
struct EmbeddingPromptsTests {
    let prompts = EmbeddingPrompts(query: "task: search result | query: {text}", document: "title: {title} | text: {text}")

    @Test func render() {
        #expect(prompts.renderQuery("리스트") == "task: search result | query: 리스트")
        #expect(prompts.renderDocument(title: "강의 1", text: "본문") == "title: 강의 1 | text: 본문")
        #expect(prompts.renderDocument(title: nil, text: "본문") == "title: none | text: 본문")
        #expect(prompts.renderDocument(title: "", text: "본문") == "title: none | text: 본문")
    }

    @Test("프롬프트가 바뀌면 식별값도 바뀐다")
    func fingerprint() {
        var other = prompts
        #expect(other.fingerprint == prompts.fingerprint)
        other.query = "query: {text}"
        #expect(other.fingerprint != prompts.fingerprint)
    }
}
