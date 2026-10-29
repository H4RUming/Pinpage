import AppKit
import Foundation
import Observation
import PinpageCore
import UniformTypeIdentifiers

enum EndpointRole {
    case chat
    case embedding

    var title: String {
        switch self {
        case .chat: "Chat API"
        case .embedding: "임베딩 API"
        }
    }
}

/// 앱 전체 상태. 설정을 고치면 잠시 뒤 자동 저장한다.
@Observable @MainActor
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            if settings.embedding != oldValue.embedding || settings.chat != oldValue.chat || settings.network != oldValue.network {
                embeddingManager.refresh(settings: settings)
            }
        }
    }

    /// 실험 세션 진행 중에는 true. 마일스톤 5에서 세션과 연결한다.
    var isSettingsLocked = false

    /// 화면 위쪽에 보여줄 알림 (설정 파일 손상, 저장 실패 등).
    var banner: String?
    /// 불러오기·내보내기 결과 알림.
    var alert: AlertMessage?

    let chatState = EndpointState()
    let embeddingState = EndpointState()
    let appInfo = AppInfo.from(bundle: .main)
    /// LLM 요청 기록. 마일스톤 4에서 이벤트 로그 DB로 바꾼다.
    let callRecorder = InMemoryLLMCallRecorder()

    let embeddingManager: EmbeddingManager
    /// 학습 세트 화면 상태. 앱 데이터 폴더를 열지 못하면 nil.
    private(set) var libraryModel: LibraryModel?

    private let repository: SettingsRepository?
    private var saveTask: Task<Void, Never>?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        let dataDirectory = try? SettingsRepository.defaultDirectory()
        if let dataDirectory {
            let repository = SettingsRepository(directory: dataDirectory)
            // 처음 실행이면 앱에 들어 있는 기본 설정(임베딩 모델 저장소·버전 등)으로 시작한다.
            if FileManager.default.fileExists(atPath: repository.fileURL.path) {
                let loaded = repository.load()
                self.settings = loaded.settings
                self.banner = loaded.warning
            } else {
                self.settings = Self.bundledDefaults()
                self.banner = nil
            }
            self.repository = repository
        } else {
            self.repository = nil
            self.settings = Self.bundledDefaults()
            self.banner = "앱 데이터 폴더를 만들 수 없어 설정과 자료가 저장되지 않습니다."
        }
        let root = dataDirectory ?? FileManager.default.temporaryDirectory.appending(path: "Pinpage")
        self.embeddingManager = EmbeddingManager(modelsRoot: root.appending(path: "models"))

        if let dataDirectory {
            do {
                let database = try AppDatabase.open(at: dataDirectory.appending(path: "pinpage.sqlite"))
                let library = Library(database: database, filesRoot: dataDirectory.appending(path: "sets"))
                self.libraryModel = LibraryModel(library: library, app: self)
            } catch {
                self.banner = "자료 DB를 열 수 없습니다: \(error.localizedDescription)"
            }
        }
        if repository != nil, !FileManager.default.fileExists(atPath: repository!.fileURL.path) {
            saveNow()
        }
        embeddingManager.refresh(settings: settings)
    }

    private static func bundledDefaults() -> AppSettings {
        guard let url = Bundle.main.url(forResource: "DefaultSettings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    var settingsFileURL: URL? { repository?.fileURL }

    func state(for role: EndpointRole) -> EndpointState {
        role == .chat ? chatState : embeddingState
    }

    // MARK: - 저장

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let repository else { return }
        do {
            try repository.save(settings)
        } catch {
            banner = "설정을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 모델 목록과 연결 테스트

    private func endpoint(for role: EndpointRole) throws(EndpointError) -> APIEndpoint {
        role == .chat ? try settings.chatEndpoint() : try settings.embeddingEndpoint()
    }

    private func client(for role: EndpointRole) throws(EndpointError) -> OpenAIClient {
        OpenAIClient(
            endpoint: try endpoint(for: role),
            timeoutSeconds: settings.network.testTimeoutSeconds,
            retryPolicy: RetryPolicy(maxRetries: settings.network.maxRetries),
            recorder: callRecorder
        )
    }

    /// 주소나 키를 고친 뒤 입력이 멈추면 모델 목록을 다시 불러온다.
    func serverInputChanged(_ role: EndpointRole) {
        state(for: role).clearResults()
        scheduleModelLoad(role)
        if role == .chat && settings.embedding.useChatServer {
            embeddingState.clearResults()
            scheduleModelLoad(.embedding)
        }
    }

    private func scheduleModelLoad(_ role: EndpointRole) {
        let state = state(for: role)
        state.cancelLoad()
        guard (try? endpoint(for: role)) != nil else { return }
        state.loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.loadModels(role)
        }
    }

    func loadModels(_ role: EndpointRole) async {
        let state = state(for: role)
        let client: OpenAIClient
        do {
            client = try self.client(for: role)
        } catch {
            state.modelsError = error.message
            return
        }
        state.isLoadingModels = true
        state.modelsError = nil
        defer { state.isLoadingModels = false }
        do {
            state.models = try await client.listModels()
            state.modelsLoadedFrom = client.endpoint.baseURL.absoluteString
        } catch is CancellationError {
            return
        } catch let error as LLMRequestError {
            if error.kind == .cancelled { return }
            state.models = []
            state.modelsLoadedFrom = nil
            state.modelsError = error.message
        } catch {
            state.modelsError = error.localizedDescription
        }
    }

    func testConnection(_ role: EndpointRole) async {
        let state = state(for: role)
        let model = role == .chat ? settings.chat.model : settings.embedding.model
        let client: OpenAIClient
        do {
            client = try self.client(for: role)
        } catch {
            state.testResult = .failure(error.message)
            return
        }
        state.isTesting = true
        state.testResult = nil
        defer { state.isTesting = false }
        do {
            let result = role == .chat
                ? try await client.testChat(model: model)
                : try await client.testEmbedding(model: model)
            var text = "응답함 · \(result.latencyMs)ms"
            if let dimension = result.embeddingDimension { text += " · 벡터 \(dimension)차원" }
            if result.attempts > 1 { text += " · \(result.attempts)번 시도" }
            state.testResult = .success(text)
        } catch let error as LLMRequestError {
            state.testResult = .failure(error.message)
        } catch {
            state.testResult = .failure(error.localizedDescription)
        }
    }

    // MARK: - 설정 파일 내보내기·불러오기

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "설정 내보내기"
        panel.message = "API 키는 파일에 포함되지 않습니다."
        panel.nameFieldStringValue = SettingsTransfer.suggestedFileName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SettingsTransfer.exportData(settings, appVersion: appInfo.version)
            try data.write(to: url, options: .atomic)
            alert = AlertMessage(title: "설정을 내보냈습니다", message: "\(url.lastPathComponent)\nAPI 키는 포함하지 않았습니다.")
        } catch {
            alert = AlertMessage(title: "설정을 내보내지 못했습니다", message: error.localizedDescription)
        }
    }

    func importSettings() {
        guard !isSettingsLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "설정 불러오기"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            settings = try SettingsTransfer.importSettings(from: data, keepingSecretsFrom: settings)
            saveNow()
            chatState.clearResults()
            embeddingState.clearResults()
            Task {
                await loadModels(.chat)
                await loadModels(.embedding)
            }
            alert = AlertMessage(title: "설정을 불러왔습니다", message: "API 키는 이 Mac에 입력해 둔 값을 그대로 유지했습니다.")
        } catch {
            alert = AlertMessage(title: "설정을 불러오지 못했습니다", message: error.localizedDescription)
        }
    }
}

/// Chat 또는 임베딩 서버의 모델 목록과 연결 테스트 상태.
@Observable @MainActor
final class EndpointState {
    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var models: [String] = []
    /// 모델 목록을 받아온 base URL.
    var modelsLoadedFrom: String?
    var isLoadingModels = false
    var modelsError: String?
    var isTesting = false
    var testResult: TestResult?

    @ObservationIgnored var loadTask: Task<Void, Never>?

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    func clearResults() {
        modelsError = nil
        testResult = nil
    }
}
