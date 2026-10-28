import Foundation
import Testing
@testable import PinpageCore

private func sampleSettings() -> AppSettings {
    var s = AppSettings()
    s.chat = EndpointSettings(baseURL: "http://gpu-server:8000", apiKey: "sk-chat-secret", model: "qwen3-8b")
    s.embedding = EmbeddingSettings(useChatServer: false, baseURL: "http://100.100.10.20:8001", apiKey: "sk-embed-secret", model: "bge-m3")
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
