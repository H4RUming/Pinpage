import Foundation

/// BM25용 토큰화.
/// - 한글: 음절 2개씩 겹치게 자른다 ("리스트와" → 리스, 스트, 트와). 한 글자짜리 덩어리는 그대로 쓴다.
///   조사가 붙어도("리스트를") 앞부분이 맞고, OS 버전과 관계없이 결과가 항상 같다.
/// - 영문·숫자: 단어 단위, 소문자 ("binary_search" → binary, search)
/// - 그 밖의 글자(한자 등): 한 글자씩
public enum BM25Tokenizer {
    public static func tokens(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var tokens: [String] = []
        var hangul: [Character] = []
        var word = ""

        func flushHangul() {
            if hangul.count == 1 {
                tokens.append(String(hangul[0]))
            } else if hangul.count > 1 {
                for i in 0..<(hangul.count - 1) { tokens.append(String(hangul[i...i + 1])) }
            }
            hangul.removeAll()
        }
        func flushWord() {
            if !word.isEmpty { tokens.append(word); word = "" }
        }

        for ch in normalized {
            if isHangulSyllable(ch) {
                flushWord()
                hangul.append(ch)
            } else if ch.isASCII && (ch.isLetter || ch.isNumber) {
                flushHangul()
                word.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushHangul()
                flushWord()
                tokens.append(String(ch))
            } else {
                flushHangul()
                flushWord()
            }
        }
        flushHangul()
        flushWord()
        return tokens
    }

    private static func isHangulSyllable(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0xAC00...0xD7A3).contains(scalar.value)
    }
}

/// 메모리 BM25 색인 (k1 = 1.2, b = 0.75).
public struct BM25Index: Sendable {
    public static let k1 = 1.2
    public static let b = 0.75

    private let ids: [Int64]
    private let termFrequencies: [[String: Int]]
    private let lengths: [Int]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    public init(documents: [(id: Int64, text: String)]) {
        ids = documents.map(\.id)
        var tfs: [[String: Int]] = []
        var df: [String: Int] = [:]
        var lengths: [Int] = []
        for doc in documents {
            let tokens = BM25Tokenizer.tokens(doc.text)
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            for t in tf.keys { df[t, default: 0] += 1 }
            tfs.append(tf)
            lengths.append(tokens.count)
        }
        termFrequencies = tfs
        documentFrequency = df
        self.lengths = lengths
        averageLength = lengths.isEmpty ? 0 : Double(lengths.reduce(0, +)) / Double(lengths.count)
    }

    public var count: Int { ids.count }

    /// 모든 문서의 점수. 질문 단어가 하나도 없으면 0.
    public func scores(for query: String) -> [Int64: Double] {
        let terms = Set(BM25Tokenizer.tokens(query))
        let n = Double(ids.count)
        var result: [Int64: Double] = [:]
        for (i, tf) in termFrequencies.enumerated() {
            var score = 0.0
            let lengthNorm = Self.k1 * (1 - Self.b + Self.b * Double(lengths[i]) / max(averageLength, 1))
            for term in terms {
                guard let f = tf[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                score += idf * Double(f) * (Self.k1 + 1) / (Double(f) + lengthNorm)
            }
            result[ids[i]] = score
        }
        return result
    }
}
