import Foundation
import Testing
@testable import PinpageCore

@Suite("Gemma 토크나이저", .enabled(if: EmbeddingModelFixture.isAvailable, "임베딩 모델 폴더가 없음"))
struct GemmaTokenizerTests {
    @Test("Python tokenizers와 토큰 ID가 같다", arguments: 0..<EmbeddingModelFixture.golden.count)
    func matchesPython(index: Int) throws {
        let tokenizer = try #require(EmbeddingModelFixture.tokenizer)
        let golden = EmbeddingModelFixture.golden[index]
        #expect(tokenizer.encode(golden.text) == golden.ids, "\(golden.text.prefix(40))")
    }

    @Test("특수 토큰 ID")
    func specialTokens() throws {
        let tokenizer = try #require(EmbeddingModelFixture.tokenizer)
        #expect(tokenizer.bosID == 2)
        #expect(tokenizer.eosID == 1)
    }

    @Test("빈 문자열")
    func empty() throws {
        let tokenizer = try #require(EmbeddingModelFixture.tokenizer)
        #expect(tokenizer.encode("").isEmpty)
    }
}

@Suite("최소 힙")
struct MinHeapTests {
    @Test func ordersElements() {
        var heap = MinHeap<Int>()
        for x in [5, 1, 4, 1, 9, 2, 6] { heap.push(x) }
        var out: [Int] = []
        while let x = heap.pop() { out.append(x) }
        #expect(out == [1, 1, 2, 4, 5, 6, 9])
    }
}
