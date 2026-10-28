import CoreML
import Foundation

/// EmbeddingGemma 2 Core ML 모델(FluidInference 변환본)로 임베딩을 만든다.
///
/// 입력 처리: 토큰화 → `<bos>` 토큰들 `<eos>` → 토큰 표(bf16)에서 행을 읽어 `embed_scale`을 곱함 →
/// 길이에 맞는 가장 작은 `embed_S` 함수 호출. 512토큰을 넘으면 자른다.
public actor CoreMLEmbedder: Embedder {
    public nonisolated let key: String
    public nonisolated let dimension: Int

    private let tokenizer: GemmaTokenizer
    private let table: Data
    private let hiddenSize: Int
    private let embedScale: Float
    private let sizes: [Int]
    private let compiledModelURL: URL
    private let computeUnit: EmbeddingComputeUnit
    private var models: [Int: MLModel] = [:]

    static let packageName = "EmbeddingGemma2Text.mlpackage"

    /// - Parameters:
    ///   - modelDirectory: 설치된 모델 폴더 (manifest.json 기준으로 검증된 상태)
    ///   - cacheDirectory: 컴파일한 모델(.mlmodelc)을 둘 폴더
    ///   - key: 색인 식별값 (모델 버전, 연산 장치, 차원, 프롬프트를 담는다)
    public init(modelDirectory: URL, cacheDirectory: URL, computeUnit: EmbeddingComputeUnit, dimension: Int, key: String) async throws {
        let config = try ModelConfig(url: modelDirectory.appending(path: "config.json"))
        guard config.matryoshkaDims.contains(dimension) || dimension == config.embeddingDim else {
            throw CoreMLEmbedderError.unsupportedDimension(dimension)
        }
        let tableURL = modelDirectory.appending(path: config.tokenTableFile)
        let table = try Data(contentsOf: tableURL, options: .alwaysMapped)
        guard table.count == config.tokenTableRows * config.hiddenSize * 2 else {
            throw CoreMLEmbedderError.badTokenTable
        }

        self.tokenizer = try GemmaTokenizer(contentsOf: modelDirectory.appending(path: "tokenizer.json"))
        self.table = table
        self.hiddenSize = config.hiddenSize
        self.embedScale = config.embedScale
        self.sizes = config.embedSizes
        self.dimension = dimension
        self.computeUnit = computeUnit
        self.key = key
        self.compiledModelURL = try await Self.compiledModel(
            package: modelDirectory.appending(path: Self.packageName),
            cacheDirectory: cacheDirectory
        )
    }

    /// 모든 길이의 함수를 미리 불러온다. 기기에서 처음이면 연산 장치용 컴파일로 수십 초 걸린다.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        for (index, size) in sizes.enumerated() {
            _ = try await model(for: size)
            progress?(Double(index + 1) / Double(sizes.count))
        }
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            vectors.append(try await embedOne(text))
        }
        return vectors
    }

    public func tokenCount(_ text: String) -> Int {
        min(tokenizer.encode(text).count, maxTokens - 2) + 2
    }

    private var maxTokens: Int { sizes.last ?? 512 }

    private func embedOne(_ text: String) async throws -> [Float] {
        var ids = tokenizer.encode(text)
        if ids.count > maxTokens - 2 { ids = Array(ids.prefix(maxTokens - 2)) }
        ids = [tokenizer.bosID] + ids + [tokenizer.eosID]
        guard let size = sizes.first(where: { $0 >= ids.count }) else { throw CoreMLEmbedderError.inputTooLong }

        let embeds = try MLMultiArray(shape: [1, NSNumber(value: size), NSNumber(value: hiddenSize)], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .float16)
        let hidden = hiddenSize
        let scale = embedScale
        table.withUnsafeBytes { raw in
            let rows = raw.bindMemory(to: UInt16.self)
            embeds.withUnsafeMutableBufferPointer(ofType: Float16.self) { out, strides in
                let tStride = strides[1], dStride = strides[2]
                for t in 0..<size {
                    for d in 0..<hidden { out[t * tStride + d * dStride] = 0 }
                }
                for (t, id) in ids.enumerated() {
                    let base = Int(id) * hidden
                    for d in 0..<hidden {
                        let bf16 = UInt16(littleEndian: rows[base + d])
                        out[t * tStride + d * dStride] = Float16(Float(bitPattern: UInt32(bf16) << 16) * scale)
                    }
                }
            }
            mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { out, strides in
                let tStride = strides[1]
                for t in 0..<size { out[t * tStride] = t < ids.count ? 1 : 0 }
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: embeds),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        // 액터 안에서 동기 예측을 쓴다 (MLModel은 Sendable이 아니므로 비동기 예측으로 넘기지 않는다).
        let output = try Self.predict(try await model(for: size), input)
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw CoreMLEmbedderError.missingOutput
        }
        return VectorMath.normalized(Array(Self.floats(embedding).prefix(dimension)))
    }

    private func model(for size: Int) async throws -> MLModel {
        if let model = models[size] { return model }
        let configuration = MLModelConfiguration()
        configuration.functionName = "embed_\(size)"
        configuration.computeUnits = switch computeUnit {
        case .gpu: .cpuAndGPU
        case .neuralEngine: .cpuAndNeuralEngine
        case .cpu: .cpuOnly
        }
        let model = try await MLModel.load(contentsOf: compiledModelURL, configuration: configuration)
        models[size] = model
        return model
    }

    private static func predict(_ model: MLModel, _ input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { Array($0.prefix(count)).map(Float.init) }
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count)) }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// .mlpackage를 한 번만 컴파일해 cacheDirectory에 둔다. 원본 크기가 바뀌면 다시 컴파일한다.
    private static func compiledModel(package: URL, cacheDirectory: URL) async throws -> URL {
        let fm = FileManager.default
        let destination = cacheDirectory.appending(path: "EmbeddingGemma2Text.mlmodelc")
        let marker = cacheDirectory.appending(path: "compiled-from.txt")
        let weights = package.appending(path: "Data/com.apple.CoreML/weights/weight.bin")
        let signature = "\((try? fm.attributesOfItem(atPath: weights.path)[.size] as? Int) ?? -1)"

        if fm.fileExists(atPath: destination.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == signature {
            return destination
        }
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let compiled = try await MLModel.compileModel(at: package)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: compiled, to: destination)
        try signature.write(to: marker, atomically: true, encoding: .utf8)
        return destination
    }
}

/// 모델 폴더의 config.json 중 필요한 값.
struct ModelConfig {
    let hiddenSize: Int
    let embeddingDim: Int
    let matryoshkaDims: [Int]
    let embedScale: Float
    let embedSizes: [Int]
    let tokenTableFile: String
    let tokenTableRows: Int

    init(url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let hidden = root["hidden_size"] as? Int,
              let dim = root["embedding_dim"] as? Int,
              let scale = root["embed_scale"] as? Double,
              let functions = root["functions"] as? [String: Any],
              let table = root["token_table"] as? [String: Any],
              let tableFile = table["file"] as? String,
              let shape = table["shape"] as? [Int], shape.count == 2, shape[1] == hidden
        else {
            throw CoreMLEmbedderError.badConfig
        }
        hiddenSize = hidden
        embeddingDim = dim
        matryoshkaDims = root["matryoshka_dims"] as? [Int] ?? [dim]
        embedScale = Float(scale)
        embedSizes = functions.keys
            .filter { $0.hasPrefix("embed_") }
            .compactMap { Int($0.dropFirst("embed_".count)) }
            .sorted()
        tokenTableFile = tableFile
        tokenTableRows = shape[0]
        guard !embedSizes.isEmpty else { throw CoreMLEmbedderError.badConfig }
    }
}

public enum CoreMLEmbedderError: Error, LocalizedError {
    case badConfig
    case badTokenTable
    case unsupportedDimension(Int)
    case inputTooLong
    case missingOutput

    public var errorDescription: String? {
        switch self {
        case .badConfig: "임베딩 모델 설정(config.json)을 읽을 수 없습니다."
        case .badTokenTable: "임베딩 모델의 토큰 표 파일 크기가 맞지 않습니다. 모델을 다시 설치하세요."
        case .unsupportedDimension(let d): "이 모델은 \(d)차원을 지원하지 않습니다."
        case .inputTooLong: "입력이 너무 깁니다."
        case .missingOutput: "임베딩 모델 출력이 없습니다."
        }
    }
}
