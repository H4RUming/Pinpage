import CryptoKit
import Foundation

/// 내려받을 임베딩 모델의 위치와 고정 버전.
public struct EmbeddingModelSource: Equatable, Sendable {
    public let repo: String
    public let revision: String
    /// 저장소 manifest.json의 SHA-256. 이 값이 같으면 모든 파일이 같다.
    public let manifestSHA256: String

    public init(repo: String, revision: String, manifestSHA256: String) {
        self.repo = repo
        self.revision = revision
        self.manifestSHA256 = manifestSHA256.lowercased()
    }

    public init(settings: EmbeddingSettings) {
        self.init(repo: settings.modelRepo, revision: settings.modelRevision, manifestSHA256: settings.modelManifestSHA256)
    }

    var directoryName: String {
        "\(repo.replacingOccurrences(of: "/", with: "--"))@\(revision.prefix(12))"
    }

    func fileURL(_ path: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")
    }
}

/// 모델 폴더의 manifest.json (Tools/prepare_embedding_model.py가 만든다).
public struct ModelManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }
    public let format: String
    public let formatVersion: Int
    public let files: [File]

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ModelInstallProgress: Sendable, Equatable {
    case fetchingManifest
    /// 전체 바이트 기준 진행률
    case downloading(file: String, completed: Int64, total: Int64)
    case verifying(file: String)
}

/// 임베딩 모델을 Hugging Face에서 내려받거나 폴더에서 설치하고, 모든 파일을 SHA-256으로 검증한다.
/// 설치 위치: `Application Support/Pinpage/models/<저장소>@<버전>/`
public struct EmbeddingModelInstaller: Sendable {
    public let root: URL
    private let session: URLSession
    private let maxRetries: Int

    private static let markerName = "installed.json"

    private struct Marker: Codable {
        let repo: String
        let revision: String
        let manifestSHA256: String
        let installedAt: Date
    }

    public init(root: URL, session: URLSession = .shared, maxRetries: Int = 2) {
        self.root = root
        self.session = session
        self.maxRetries = maxRetries
    }

    public func directory(for source: EmbeddingModelSource) -> URL {
        root.appending(path: source.directoryName, directoryHint: .isDirectory)
    }

    /// 설치가 끝난 폴더. 표시 파일과 파일 크기만 빠르게 확인한다 (해시는 설치할 때 검증했다).
    public func installedDirectory(for source: EmbeddingModelSource) -> URL? {
        let dir = directory(for: source)
        guard let markerData = try? Data(contentsOf: dir.appending(path: Self.markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: markerData),
              marker.manifestSHA256 == source.manifestSHA256,
              let manifestData = try? Data(contentsOf: dir.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: manifestData)
        else { return nil }
        for file in manifest.files {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: file.path).path)[.size] as? Int64) ?? -1
            if size != file.size { return nil }
        }
        return dir
    }

    // MARK: - 내려받기

    public func download(_ source: EmbeddingModelSource, progress: (@Sendable (ModelInstallProgress) -> Void)? = nil) async throws -> URL {
        progress?(.fetchingManifest)
        guard let manifestURL = source.fileURL("manifest.json") else { throw ModelInstallError.badSource }
        let (manifestData, response) = try await withRetries { try await session.data(from: manifestURL) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelInstallError.http(status: http.statusCode, file: "manifest.json")
        }
        let manifest = try Self.checkManifest(manifestData, expected: source.manifestSHA256)

        let staging = root.appending(path: ".staging-\(source.directoryName)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try manifestData.write(to: staging.appending(path: "manifest.json"))

        var completed: Int64 = 0
        let total = manifest.totalSize
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = staging.appending(path: file.path)
            // 앞서 받다 만 파일이 온전하면 다시 받지 않는다.
            if Self.size(of: destination) == file.size, (try? Self.sha256(of: destination)) == file.sha256 {
                completed += file.size
                progress?(.downloading(file: file.path, completed: completed, total: total))
                continue
            }
            guard let url = source.fileURL(file.path) else { throw ModelInstallError.badSource }
            let base = completed
            let delegate = DownloadProgressDelegate { written in
                progress?(.downloading(file: file.path, completed: base + written, total: total))
            }
            let temporary = try await downloadFile(url, name: file.path, delegate: delegate)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)

            progress?(.verifying(file: file.path))
            try Self.verify(destination, file)
            completed += file.size
            progress?(.downloading(file: file.path, completed: completed, total: total))
        }
        return try finish(staging: staging, source: source)
    }

    private func downloadFile(_ url: URL, name: String, delegate: DownloadProgressDelegate) async throws -> URL {
        var resumeData: Data?
        var attempt = 0
        while true {
            do {
                let (location, response) = if let data = resumeData {
                    try await session.download(resumeFrom: data, delegate: delegate)
                } else {
                    try await session.download(from: url, delegate: delegate)
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ModelInstallError.http(status: http.statusCode, file: name)
                }
                // 임시 파일은 곧 지워지므로 옮겨 둔다.
                let kept = FileManager.default.temporaryDirectory.appending(path: "pinpage-model-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: location, to: kept)
                return kept
            } catch let error as URLError where attempt < maxRetries && error.code != .cancelled {
                attempt += 1
                resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    private func withRetries<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let error as URLError where attempt < maxRetries && error.code != .cancelled {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    // MARK: - 폴더에서 설치 (인터넷 없이)

    /// 진행자가 나눠준 모델 폴더를 검증해서 설치한다. manifest.json이 고정 버전과 같아야 한다.
    public func installFromFolder(_ folder: URL, source: EmbeddingModelSource, progress: (@Sendable (ModelInstallProgress) -> Void)? = nil) throws -> URL {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: folder.appending(path: "manifest.json"))
        } catch {
            throw ModelInstallError.missingFile("manifest.json")
        }
        let manifest = try Self.checkManifest(manifestData, expected: source.manifestSHA256)
        let staging = root.appending(path: ".staging-\(source.directoryName)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try manifestData.write(to: staging.appending(path: "manifest.json"))
        for file in manifest.files {
            let from = folder.appending(path: file.path)
            guard FileManager.default.fileExists(atPath: from.path) else { throw ModelInstallError.missingFile(file.path) }
            progress?(.verifying(file: file.path))
            try Self.verify(from, file)
            let to = staging.appending(path: file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
        }
        return try finish(staging: staging, source: source)
    }

    public func remove(_ source: EmbeddingModelSource) throws {
        let dir = directory(for: source)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: - 공통

    private func finish(staging: URL, source: EmbeddingModelSource) throws -> URL {
        let marker = Marker(repo: source.repo, revision: source.revision, manifestSHA256: source.manifestSHA256, installedAt: Date())
        try JSONEncoder().encode(marker).write(to: staging.appending(path: Self.markerName))
        let destination = directory(for: source)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    static func checkManifest(_ data: Data, expected: String) throws -> ModelManifest {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw ModelInstallError.manifestMismatch }
        guard let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              manifest.format == "pinpage-embedding-model",
              manifest.files.allSatisfy({ !$0.path.contains("..") && !$0.path.hasPrefix("/") })
        else { throw ModelInstallError.badManifest }
        return manifest
    }

    static func verify(_ url: URL, _ file: ModelManifest.File) throws {
        guard size(of: url) == file.size, try sha256(of: url) == file.sha256 else {
            throw ModelInstallError.checksumMismatch(file.path)
        }
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 파일 하나를 받는 동안의 진행률을 알린다.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum ModelInstallError: Error, LocalizedError, Equatable {
    case badSource
    case http(status: Int, file: String)
    case manifestMismatch
    case badManifest
    case missingFile(String)
    case checksumMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .badSource:
            "임베딩 모델 저장소 주소가 올바르지 않습니다. 설정을 확인하세요."
        case .http(let status, let file):
            status == 404
                ? "모델 파일(\(file))을 찾을 수 없습니다(404). 설정의 저장소와 버전을 확인하세요."
                : "모델 파일(\(file))을 받지 못했습니다(HTTP \(status))."
        case .manifestMismatch:
            "모델 버전이 설정과 다릅니다(manifest.json 검증값 불일치). 진행자가 준 설정 파일과 모델을 확인하세요."
        case .badManifest:
            "모델 폴더의 manifest.json 형식이 올바르지 않습니다."
        case .missingFile(let path):
            "모델 폴더에 '\(path)' 파일이 없습니다."
        case .checksumMismatch(let path):
            "'\(path)' 파일이 손상되었거나 다른 파일입니다(SHA-256 불일치). 다시 받으세요."
        }
    }
}
