import Foundation

/// 문장을 벡터로 바꾼다. 앱 내장(Core ML)과 원격 API가 같은 형식으로 동작한다.
public protocol Embedder: Sendable {
    /// 벡터 공간을 식별하는 값. 이 값이 바뀌면 색인을 다시 만들어야 한다.
    var key: String { get }
    /// L2 정규화된 벡터를 입력 순서대로 돌려준다.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// 임베딩 연산 장치.
public enum EmbeddingComputeUnit: String, Codable, CaseIterable, Sendable {
    case gpu
    case neuralEngine
    case cpu

    public var label: String {
        switch self {
        case .gpu: "GPU"
        case .neuralEngine: "Neural Engine"
        case .cpu: "CPU"
        }
    }
}

/// 임베딩 앞에 붙이는 작업 프롬프트. 코드에 넣지 않고 템플릿 파일에서 읽는다.
/// `{text}`, `{title}` 자리에 값을 넣는다.
public struct EmbeddingPrompts: Codable, Equatable, Sendable {
    public var query: String
    public var document: String

    public init(query: String, document: String) {
        self.query = query
        self.document = document
    }

    public func renderQuery(_ text: String) -> String {
        query.replacingOccurrences(of: "{text}", with: text)
    }

    /// 제목이 없으면 `none`을 넣는다 (EmbeddingGemma 문서 형식).
    public func renderDocument(title: String?, text: String) -> String {
        let title = title.flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        return document
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{text}", with: text)
    }

    /// 프롬프트가 바뀌면 벡터도 바뀌므로 색인 식별값에 넣는다.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
        for byte in (query + "\u{1}" + document).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

enum VectorMath {
    static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }
}
