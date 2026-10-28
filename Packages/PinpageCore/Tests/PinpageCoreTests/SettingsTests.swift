import Foundation
import Testing
@testable import PinpageCore

private func sampleSettings() -> AppSettings {
    var s = AppSettings()
    s.chat = EndpointSettings(baseURL: "http://gpu-server:8000", apiKey: "sk-chat-secret", model: "qwen3-8b")
    s.embedding = EmbeddingSettings(useChatServer: false, baseURL: "http://100.100.10.20:8001", apiKey: "sk-embed-secret", model: "bge-m3")
    s.embedding.mode = .remote
    s.network.maxRetries = 4
    s.network.requestTimeoutSeconds = 180
    s.retrieval.topK = 8
    s.retrieval.embeddingWeight = 0.3
    s.learning.quizPassThreshold = 0.7
    return s
}

@Suite("설정 모델")
struct AppSettingsTests {
    @Test("기본값")
    func defaults() {
        let s = AppSettings()
        #expect(s.learning.quizPassThreshold == 0.8)
        #expect(s.learning.hintLevels == 3)
        #expect(s.embedding.useChatServer)
        #expect(s.validate().isEmpty)
    }

    @Test("파일에 없는 필드는 기본값으로 채운다")
    func missingFields() throws {
        let data = Data(#"{"chat": {"baseURL": "gpu-server:8000"}, "network": {"maxRetries": 5}}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(s.chat.baseURL == "gpu-server:8000")
        #expect(s.chat.model == "")
        #expect(s.network.maxRetries == 5)
        #expect(s.network.testTimeoutSeconds == 10)
        #expect(s.retrieval == RetrievalSettings())
        #expect(s.schemaVersion == AppSettings.currentSchemaVersion)
    }

    @Test("잘못된 값을 모두 찾는다")
    func validation() {
        var s = AppSettings()
        s.chat.baseURL = "ftp://x"
        s.network.maxRetries = 99
        s.retrieval.chunkSize = 200
        s.retrieval.chunkOverlap = 300
        s.learning.quizPassThreshold = 1.5
        let fields = s.validate().map(\.field)
        #expect(fields.contains("Chat API 주소"))
        #expect(fields.contains("최대 재시도 횟수"))
        #expect(fields.contains("청크 겹침"))
        #expect(fields.contains("퀴즈 통과 기준"))
    }

    @Test("임베딩이 Chat 서버를 같이 쓰면 Chat 주소와 키를 쓴다")
    func embeddingEndpoint() throws {
        var s = sampleSettings()
        s.embedding.useChatServer = true
        let shared = try s.embeddingEndpoint()
        #expect(shared.baseURL.absoluteString == "http://gpu-server:8000/v1")
        #expect(shared.apiKey == "sk-chat-secret")

        s.embedding.useChatServer = false
        let separate = try s.embeddingEndpoint()
        #expect(separate.baseURL.absoluteString == "http://100.100.10.20:8001/v1")
        #expect(separate.apiKey == "sk-embed-secret")
    }

    @Test("mode가 없던 이전 설정 파일은 원격 모델 지정 여부로 방식을 정한다")
    func legacyEmbeddingMode() throws {
        let remote = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"embedding":{"model":"bge-m3"}}"#.utf8))
        #expect(remote.embedding.mode == .remote)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"embedding":{"model":""}}"#.utf8))
        #expect(off.embedding.mode == .off)
        #expect(off.embedding.computeUnit == .gpu)
        #expect(off.embedding.dimension == 768)
    }

    @Test("앱 내장 임베딩 설정 검증")
    func builtinValidation() {
        var s = AppSettings()
        s.embedding.mode = .builtin
        #expect(Set(s.validate().map(\.field)) == ["임베딩 모델 저장소", "임베딩 모델 버전", "임베딩 모델 검증값"])
        s.embedding.modelRepo = "H4RUming/embeddinggemma-2-coreml-text"
        s.embedding.modelRevision = "abdbb538c8013f897003dfc8861a012480d5e584"
        s.embedding.modelManifestSHA256 = String(repeating: "a", count: 64)
        #expect(s.validate().isEmpty)
        s.embedding.dimension = 300
        #expect(s.validate().map(\.field) == ["임베딩 차원"])
    }

    @Test("색인 식별값은 모델, 연산 장치, 차원, 프롬프트가 바뀌면 달라진다")
    func embedderKey() {
        let prompts = EmbeddingPrompts(query: "q: {text}", document: "d: {text}")
        var s = AppSettings()
        #expect(s.embedderKey(prompts: prompts) == nil)
        s.embedding.mode = .builtin
        s.embedding.modelRepo = "a/b"
        s.embedding.modelRevision = "r1"
        let base = s.embedderKey(prompts: prompts)
        #expect(base != nil)
        var other = s; other.embedding.computeUnit = .neuralEngine
        #expect(other.embedderKey(prompts: prompts) != base)
        other = s; other.embedding.dimension = 256
        #expect(other.embedderKey(prompts: prompts) != base)
        other = s; other.embedding.modelRevision = "r2"
        #expect(other.embedderKey(prompts: prompts) != base)
        #expect(s.embedderKey(prompts: EmbeddingPrompts(query: "x {text}", document: "d: {text}")) != base)
    }

    @Test("임베딩 모델이 없으면 BM25만 사용")
    func embeddingConfigured() {
        var s = sampleSettings()
        #expect(s.isEmbeddingConfigured)
        s.embedding.model = ""
        #expect(!s.isEmbeddingConfigured)
    }
}

@Suite("설정 내보내기와 불러오기")
struct SettingsTransferTests {
    @Test("내보낸 파일에는 API 키가 절대 들어가지 않는다")
    func exportExcludesKeys() throws {
        let data = try SettingsTransfer.exportData(sampleSettings(), appVersion: "0.1.0")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sk-chat-secret"))
        #expect(!text.contains("sk-embed-secret"))
        #expect(!text.contains("apiKey"))
    }

    @Test("앱 내장 임베딩 설정도 내보내고 불러온다")
    func exportBuiltinEmbedding() throws {
        var original = sampleSettings()
        original.embedding.mode = .builtin
        original.embedding.modelRepo = "H4RUming/embeddinggemma-2-coreml-text"
        original.embedding.modelRevision = "abdbb538c8013f897003dfc8861a012480d5e584"
        original.embedding.modelManifestSHA256 = "f1c2ccaff197ef4735f1676f1efe0347fc7520c85476aa2749e8ee3a03ec554c"
        original.embedding.computeUnit = .neuralEngine
        original.embedding.dimension = 512
        original.retrieval.ocrLanguages = ["ko-KR"]
        let data = try SettingsTransfer.exportData(original, appVersion: "0.1.0")
        let imported = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: original)
        #expect(imported == original)
    }

    @Test("내보낸 파일의 머리 정보")
    func exportHeader() throws {
        let date = Date(timeIntervalSince1970: 1_793_169_000)  // 2026-10-28 06:30 UTC
        let data = try SettingsTransfer.exportData(sampleSettings(), appVersion: "0.1.0", now: date)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "pinpage-settings")
        #expect(object["schemaVersion"] as? Int == AppSettings.currentSchemaVersion)
        #expect(object["appVersion"] as? String == "0.1.0")
        #expect(object["exportedAt"] as? String != nil)
        #expect(SettingsTransfer.iso8601(date, timeZone: TimeZone(identifier: "Asia/Seoul")!) == "2026-10-28T15:30:00+09:00")
    }

    @Test("내보낸 뒤 불러오면 키를 뺀 모든 값이 같다")
    func roundTrip() throws {
        let original = sampleSettings()
        let data = try SettingsTransfer.exportData(original, appVersion: "0.1.0")
        let imported = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: original)
        #expect(imported == original)
    }

    @Test("불러와도 참가자가 입력해 둔 키는 그대로 유지한다")
    func importKeepsLocalKeys() throws {
        let facilitator = sampleSettings()
        let data = try SettingsTransfer.exportData(facilitator, appVersion: "0.1.0")

        var participant = AppSettings()
        participant.chat.apiKey = "participant-key"
        participant.chat.model = "other-model"
        let imported = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: participant)
        #expect(imported.chat.apiKey == "participant-key")
        #expect(imported.embedding.apiKey == "")
        #expect(imported.chat.model == "qwen3-8b")
        #expect(imported.network.maxRetries == 4)
    }

    @Test("손으로 키를 넣은 파일이어도 키는 무시한다")
    func importIgnoresKeysInFile() throws {
        let data = Data(#"{"format":"pinpage-settings","schemaVersion":1,"appVersion":"x","exportedAt":"x","settings":{"chat":{"baseURL":"gpu-server","apiKey":"leaked","model":"m"}}}"#.utf8)
        let imported = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: AppSettings())
        #expect(imported.chat.apiKey == "")
        #expect(imported.chat.model == "m")
    }

    @Test("잘못된 파일은 이유와 함께 거부한다")
    func rejects() throws {
        let current = AppSettings()
        #expect(throws: SettingsImportError.notJSON) {
            try SettingsTransfer.importSettings(from: Data("not json".utf8), keepingSecretsFrom: current)
        }
        #expect(throws: SettingsImportError.wrongFormat) {
            try SettingsTransfer.importSettings(from: Data(#"{"chat":{}}"#.utf8), keepingSecretsFrom: current)
        }
        #expect(throws: SettingsImportError.newerSchema(99)) {
            try SettingsTransfer.importSettings(from: Data(#"{"format":"pinpage-settings","schemaVersion":99}"#.utf8), keepingSecretsFrom: current)
        }

        var bad = sampleSettings()
        bad.retrieval.topK = 0
        let data = try SettingsTransfer.exportData(bad, appVersion: "0.1.0")
        do {
            _ = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: current)
            Issue.record("잘못된 값을 받아들였습니다")
        } catch {
            guard case .invalidValues(let issues) = error else { Issue.record("\(error)"); return }
            #expect(issues.map(\.field) == ["검색 결과 개수"])
            #expect(error.errorDescription?.contains("검색 결과 개수") == true)
        }
    }

    @Test("기본 파일 이름")
    func fileName() {
        let name = SettingsTransfer.suggestedFileName()
        #expect(name.hasPrefix("pinpage-settings-"))
        #expect(name.hasSuffix(".json"))
    }
}

@Suite("설정 저장소")
struct SettingsRepositoryTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "pinpage-tests-\(UUID().uuidString)")
    }

    @Test("저장한 값을 그대로 읽는다 (키 포함, 권한 600)")
    func saveAndLoad() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = SettingsRepository(directory: dir)
        try repository.save(sampleSettings())

        let result = repository.load()
        #expect(result.settings == sampleSettings())
        #expect(result.warning == nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("파일이 없으면 기본값")
    func missingFile() {
        let result = SettingsRepository(directory: tempDirectory()).load()
        #expect(result.settings == AppSettings())
        #expect(result.warning == nil)
    }

    @Test("손상된 파일은 보관하고 기본값으로 시작한다")
    func corruptFile() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repository = SettingsRepository(directory: dir)
        try Data("{broken".utf8).write(to: repository.fileURL)

        let result = repository.load()
        #expect(result.settings == AppSettings())
        #expect(result.warning != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("settings.corrupt-") })
        #expect(!files.contains("settings.json"))
    }
}
