import Foundation

/// Gemma `tokenizer.json`(BPE, byte fallback)을 읽어 Hugging Face tokenizers와 같은 토큰 ID를 만든다.
///
/// 이 토크나이저의 동작:
/// 1. 공백을 `▁`로 바꾼다 (normalizer: Replace)
/// 2. pre-tokenizer는 공백으로 나누지만 1번에서 공백이 사라지므로 문장 전체가 한 덩어리다
/// 3. 유니코드 스칼라 단위로 시작해 merges 순위대로 합친다. 사전에 없는 글자는 UTF-8 바이트 토큰(`<0xAB>`)으로 쪼갠다
///
/// Swift `String`은 정준 동치(예: 완성형 한글과 자모 조합)를 같은 값으로 보므로, 사전 키는 UTF-8 바이트로 비교한다.
public struct GemmaTokenizer: Sendable {
    public let bosID: Int32
    public let eosID: Int32

    private let vocab: [ByteKey: Int32]
    /// (왼쪽 ID, 오른쪽 ID) → (순위, 합친 ID)
    private let merges: [UInt64: Merge]
    private let addedTokens: [(bytes: [UInt8], id: Int32)]
    private let byteTokens: [Int32]
    private let unkID: Int32?

    private struct Merge: Sendable {
        let rank: Int32
        let newID: Int32
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              model["type"] as? String == "BPE",
              let rawVocab = model["vocab"] as? [String: Int],
              let rawMerges = model["merges"] as? [Any]
        else {
            throw GemmaTokenizerError.unsupportedFormat
        }

        var vocab: [ByteKey: Int32] = [:]
        vocab.reserveCapacity(rawVocab.count)
        for (token, id) in rawVocab {
            vocab[ByteKey(token)] = Int32(id)
        }

        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(rawMerges.count)
        for (rank, entry) in rawMerges.enumerated() {
            let pair: [String]
            if let array = entry as? [String], array.count == 2 {
                pair = array
            } else if let line = entry as? String {
                pair = line.split(separator: " ", maxSplits: 1).map(String.init)
            } else {
                continue
            }
            guard pair.count == 2,
                  let left = vocab[ByteKey(pair[0])],
                  let right = vocab[ByteKey(pair[1])],
                  let merged = vocab[ByteKey(pair[0] + pair[1])]
            else { continue }
            let key = Self.pairKey(left, right)
            if merges[key] == nil {
                merges[key] = Merge(rank: Int32(rank), newID: merged)
            }
        }

        var added: [(bytes: [UInt8], id: Int32)] = []
        for item in root["added_tokens"] as? [[String: Any]] ?? [] {
            if let content = item["content"] as? String, let id = item["id"] as? Int, !content.isEmpty {
                added.append((Array(content.utf8), Int32(id)))
            }
        }
        // 긴 토큰부터 맞춰 본다.
        added.sort { $0.bytes.count > $1.bytes.count }

        guard let bos = vocab[ByteKey("<bos>")], let eos = vocab[ByteKey("<eos>")] else {
            throw GemmaTokenizerError.missingSpecialTokens
        }
        let byteTokens = (0...255).map { vocab[ByteKey(String(format: "<0x%02X>", $0))] ?? -1 }

        self.vocab = vocab
        self.merges = merges
        self.addedTokens = added
        self.byteTokens = byteTokens
        self.unkID = (model["unk_token"] as? String).flatMap { vocab[ByteKey($0)] }
        self.bosID = bos
        self.eosID = eos
    }

    /// 특수 토큰(`<bos>`, `<eos>`) 없이 토큰 ID를 만든다.
    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        for segment in splitAddedTokens(Array(text.utf8)) {
            switch segment {
            case .added(let id):
                ids.append(id)
            case .text(let bytes):
                guard let string = String(bytes: bytes, encoding: .utf8) else { continue }
                ids.append(contentsOf: bpe(string.replacingOccurrences(of: " ", with: "▁")))
            }
        }
        return ids
    }

    // MARK: - 특수 토큰 분리

    private enum Segment {
        case text([UInt8])
        case added(Int32)
    }

    private func splitAddedTokens(_ bytes: [UInt8]) -> [Segment] {
        var segments: [Segment] = []
        var start = 0
        var i = 0
        outer: while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<") {
                for token in addedTokens where token.bytes.count <= bytes.count - i {
                    if bytes[i..<(i + token.bytes.count)].elementsEqual(token.bytes) {
                        if start < i { segments.append(.text(Array(bytes[start..<i]))) }
                        segments.append(.added(token.id))
                        i += token.bytes.count
                        start = i
                        continue outer
                    }
                }
            }
            i += 1
        }
        if start < bytes.count { segments.append(.text(Array(bytes[start...]))) }
        return segments
    }

    // MARK: - BPE

    private struct Symbol {
        var id: Int32
        var prev: Int
        var next: Int
        var alive = true
    }

    private struct Candidate: Comparable {
        let rank: Int32
        let left: Int
        let right: Int
        let leftID: Int32
        let rightID: Int32
        let newID: Int32

        static func < (a: Candidate, b: Candidate) -> Bool {
            a.rank != b.rank ? a.rank < b.rank : a.left < b.left
        }
    }

    private func bpe(_ text: String) -> [Int32] {
        var symbols: [Symbol] = []
        symbols.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            let piece = String(scalar)
            if let id = vocab[ByteKey(piece)] {
                symbols.append(Symbol(id: id, prev: symbols.count - 1, next: symbols.count + 1))
            } else {
                for byte in piece.utf8 {
                    let id = byteTokens[Int(byte)] >= 0 ? byteTokens[Int(byte)] : (unkID ?? 0)
                    symbols.append(Symbol(id: id, prev: symbols.count - 1, next: symbols.count + 1))
                }
            }
        }
        guard symbols.count > 1 else { return symbols.map(\.id) }
        symbols[symbols.count - 1].next = -1

        var heap = MinHeap<Candidate>()
        func push(_ left: Int) {
            let right = symbols[left].next
            guard right >= 0 else { return }
            if let merge = merges[Self.pairKey(symbols[left].id, symbols[right].id)] {
                heap.push(Candidate(rank: merge.rank, left: left, right: right,
                                    leftID: symbols[left].id, rightID: symbols[right].id, newID: merge.newID))
            }
        }
        for i in 0..<(symbols.count - 1) { push(i) }

        while let top = heap.pop() {
            let l = top.left, r = top.right
            guard symbols[l].alive, symbols[r].alive, symbols[l].next == r,
                  symbols[l].id == top.leftID, symbols[r].id == top.rightID
            else { continue }
            symbols[l].id = top.newID
            symbols[r].alive = false
            symbols[l].next = symbols[r].next
            if symbols[r].next >= 0 { symbols[symbols[r].next].prev = l }
            if symbols[l].prev >= 0 { push(symbols[l].prev) }
            push(l)
        }

        var ids: [Int32] = []
        var i = 0
        while i >= 0 {
            ids.append(symbols[i].id)
            i = symbols[i].next
        }
        return ids
    }

    private static func pairKey(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
    }
}

public enum GemmaTokenizerError: Error, LocalizedError {
    case unsupportedFormat
    case missingSpecialTokens

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "토크나이저 파일 형식을 읽을 수 없습니다 (BPE tokenizer.json이 아님)."
        case .missingSpecialTokens: "토크나이저에 <bos>, <eos> 토큰이 없습니다."
        }
    }
}

/// UTF-8 바이트로 비교하는 사전 키.
private struct ByteKey: Hashable, Sendable {
    let bytes: [UInt8]
    init(_ string: String) { bytes = Array(string.utf8) }
}

struct MinHeap<Element: Comparable> {
    private var items: [Element] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ element: Element) {
        items.append(element)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < items.count && items[left] < items[smallest] { smallest = left }
            if right < items.count && items[right] < items[smallest] { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
