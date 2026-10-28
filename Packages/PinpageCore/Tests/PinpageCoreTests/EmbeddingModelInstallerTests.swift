import CryptoKit
import Foundation
import Testing
@testable import PinpageCore

/// 모델 내려받기용 가짜 서버. 경로별 응답을 돌려준다 (OpenAI 클라이언트 테스트와 핸들러를 공유하지 않는다).
final class ModelServerStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    nonisolated(unsafe) private static var requested: [String] = []

    static func serve(_ files: [String: Data]) {
        lock.withLock { self.files = files; requested = [] }
    }
    static var requests: [String] { lock.withLock { requested } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let data = Self.lock.withLock { () -> Data? in
            Self.requested.append(path)
            return Self.files.first { path.hasSuffix("/" + $0.key) }?.value
        }
        let status = data == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(data?.count ?? 0)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 작은 가짜 모델 폴더 내용.
struct FakeModel {
    let files: [String: Data] = [
        "config.json": Data(#"{"hidden_size": 4}"#.utf8),
        "weights/weight.bin": Data((0..<5000).map { UInt8($0 % 251) }),
    ]

    var manifest: Data {
        let entries = files.keys.sorted().map { path in
            ["path": path, "size": files[path]!.count, "sha256": sha(files[path]!)] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["format": "pinpage-embedding-model", "formatVersion": 1, "files": entries], options: .sortedKeys)
    }

    var source: EmbeddingModelSource {
        EmbeddingModelSource(repo: "tester/model", revision: String(repeating: "a", count: 40), manifestSHA256: sha(manifest))
    }

    func writeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-model-\(UUID().uuidString)")
        for (path, data) in files {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try manifest.write(to: dir.appending(path: "manifest.json"))
        return dir
    }
}

@Suite("임베딩 모델 설치", .serialized)
struct EmbeddingModelInstallerTests {
    let model = FakeModel()

    private func installer() -> EmbeddingModelInstaller {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelServerStub.self]
        return EmbeddingModelInstaller(
            root: FileManager.default.temporaryDirectory.appending(path: "pinpage-models-\(UUID().uuidString)"),
            session: URLSession(configuration: configuration),
            maxRetries: 0
        )
    }

    @Test("고정 버전 주소에서 받아 검증하고 설치한다")
    func download() async throws {
        var served = model.files
        served["manifest.json"] = model.manifest
        ModelServerStub.serve(served)
        let installer = installer()
        #expect(installer.installedDirectory(for: model.source) == nil)

        let dir = try await installer.download(model.source)
        #expect(installer.installedDirectory(for: model.source) == dir)
        #expect(try Data(contentsOf: dir.appending(path: "weights/weight.bin")) == model.files["weights/weight.bin"])
        #expect(ModelServerStub.requests.first == "/tester/model/resolve/\(String(repeating: "a", count: 40))/manifest.json")
        #expect(ModelServerStub.requests.allSatisfy { $0.contains("/resolve/" + String(repeating: "a", count: 40) + "/") })
    }

    @Test("manifest가 고정값과 다르면 설치하지 않는다")
    func manifestMismatch() async throws {
        var served = model.files
        served["manifest.json"] = model.manifest + Data(" ".utf8)
        ModelServerStub.serve(served)
        await #expect(throws: ModelInstallError.manifestMismatch) { try await installer().download(model.source) }
    }

    @Test("내려받은 파일이 manifest와 다르면 실패한다")
    func corruptedFile() async throws {
        var served = model.files
        served["manifest.json"] = model.manifest
        served["weights/weight.bin"] = Data(repeating: 0, count: 5000)
        ModelServerStub.serve(served)
        await #expect(throws: ModelInstallError.checksumMismatch("weights/weight.bin")) { try await installer().download(model.source) }
    }

    @Test("저장소에 파일이 없으면 404를 알려준다")
    func notFound() async throws {
        ModelServerStub.serve([:])
        await #expect(throws: ModelInstallError.http(status: 404, file: "manifest.json")) { try await installer().download(model.source) }
    }

    @Test("폴더에서 설치 (인터넷 없이)")
    func folderInstall() throws {
        let folder = try model.writeFolder()
        let installer = installer()
        let dir = try installer.installFromFolder(folder, source: model.source)
        #expect(installer.installedDirectory(for: model.source) == dir)

        // 파일이 손상된 폴더
        try Data(repeating: 1, count: 5000).write(to: folder.appending(path: "weights/weight.bin"))
        #expect(throws: ModelInstallError.checksumMismatch("weights/weight.bin")) { try installer.installFromFolder(folder, source: model.source) }

        // 다른 버전의 폴더
        let other = EmbeddingModelSource(repo: "tester/model", revision: String(repeating: "b", count: 40), manifestSHA256: String(repeating: "0", count: 64))
        #expect(throws: ModelInstallError.manifestMismatch) { try installer.installFromFolder(try model.writeFolder(), source: other) }
    }

    @Test("설치 후 파일이 지워지면 설치되지 않은 것으로 본다")
    func detectsMissingFile() throws {
        let installer = installer()
        let dir = try installer.installFromFolder(try model.writeFolder(), source: model.source)
        try FileManager.default.removeItem(at: dir.appending(path: "config.json"))
        #expect(installer.installedDirectory(for: model.source) == nil)
    }

    @Test("실제 업로드한 모델 폴더가 고정 manifest와 맞는다", .enabled(if: EmbeddingModelFixture.isAvailable))
    func realManifest() throws {
        let data = try Data(contentsOf: try #require(EmbeddingModelFixture.modelDirectory).appending(path: "manifest.json"))
        let manifest = try EmbeddingModelInstaller.checkManifest(data, expected: "f1c2ccaff197ef4735f1676f1efe0347fc7520c85476aa2749e8ee3a03ec554c")
        #expect(manifest.files.count == 6)
    }
}
