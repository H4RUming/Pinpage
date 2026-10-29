import Foundation
import Observation
import PinpageCore

/// 임베딩 모델의 설치·준비 상태와 현재 쓸 수 있는 임베더.
@Observable @MainActor
final class EmbeddingManager {
    enum Status: Equatable {
        case off
        case notInstalled
        case downloading(fraction: Double, detail: String)
        case verifying(String)
        case preparing(fraction: Double)
        case ready
        case remote
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .preparing: true
            default: false
            }
        }
    }

    private(set) var status = Status.off
    /// 준비가 끝난 임베더. 없으면 검색은 BM25만 쓴다.
    private(set) var embedder: (any Embedder)?
    /// 임베딩 작업 프롬프트 (템플릿 파일에서 읽는다).
    let prompts: EmbeddingPrompts?
    let promptsError: String?

    private let installer: EmbeddingModelInstaller
    private var loadedKey: String?
    private var task: Task<Void, Never>?

    init(modelsRoot: URL) {
        installer = EmbeddingModelInstaller(root: modelsRoot)
        do {
            guard let url = Bundle.main.url(forResource: "embedding-prompts", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            prompts = try JSONDecoder().decode(EmbeddingPrompts.self, from: Data(contentsOf: url))
            promptsError = nil
        } catch {
            prompts = nil
            promptsError = "임베딩 프롬프트 템플릿(embedding-prompts.json)을 읽을 수 없어 키워드 검색만 사용합니다."
        }
    }

    /// 지금 설정으로 만든 벡터의 식별값.
    func embedderKey(for settings: AppSettings) -> String? {
        prompts.flatMap { settings.embedderKey(prompts: $0) }
    }

    /// 설정이 바뀌었거나 앱을 켰을 때 부른다. 같은 설정이면 아무것도 하지 않는다.
    func refresh(settings: AppSettings) {
        let key = embedderKey(for: settings)
        if key == loadedKey, embedder != nil || status.isBusy { return }
        task?.cancel()
        embedder = nil
        loadedKey = key

        guard let key, let prompts else {
            status = settings.embedding.mode == .off ? .off : .failed(promptsError ?? "임베딩 설정을 확인하세요.")
            return
        }
        _ = prompts
        switch settings.embedding.mode {
        case .off:
            status = .off
        case .remote:
            do {
                let client = OpenAIClient(
                    endpoint: try settings.embeddingEndpoint(),
                    timeoutSeconds: settings.network.requestTimeoutSeconds,
                    retryPolicy: RetryPolicy(maxRetries: settings.network.maxRetries)
                )
                embedder = RemoteEmbedder(client: client, model: settings.embedding.model, key: key)
                status = .remote
            } catch {
                status = .failed(error.message)
            }
        case .builtin:
            let source = EmbeddingModelSource(settings: settings.embedding)
            if let dir = installer.installedDirectory(for: source) {
                load(directory: dir, settings: settings, key: key)
            } else {
                status = .notInstalled
            }
        }
    }

    func download(settings: AppSettings) {
        let source = EmbeddingModelSource(settings: settings.embedding)
        let installer = EmbeddingModelInstaller(root: installer.root, maxRetries: settings.network.maxRetries)
        task?.cancel()
        status = .downloading(fraction: 0, detail: "목록 받는 중")
        task = Task {
            do {
                let dir = try await installer.download(source) { progress in
                    Task { @MainActor in self.show(progress) }
                }
                guard !Task.isCancelled else { return }
                loadedKey = nil
                if let key = embedderKey(for: settings) { load(directory: dir, settings: settings, key: key) }
            } catch is CancellationError {
            } catch {
                status = .failed("모델을 내려받지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    func installFromFolder(_ folder: URL, settings: AppSettings) {
        let source = EmbeddingModelSource(settings: settings.embedding)
        let installer = installer
        task?.cancel()
        status = .verifying("파일 확인 중")
        task = Task {
            do {
                let dir = try await Task.detached {
                    try installer.installFromFolder(folder, source: source) { progress in
                        Task { @MainActor in self.show(progress) }
                    }
                }.value
                loadedKey = nil
                if let key = embedderKey(for: settings) { load(directory: dir, settings: settings, key: key) }
            } catch {
                status = .failed("모델을 설치하지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if status.isBusy { status = .notInstalled }
        loadedKey = nil
    }

    private func show(_ progress: ModelInstallProgress) {
        guard status.isBusy else { return }
        switch progress {
        case .fetchingManifest:
            status = .downloading(fraction: 0, detail: "목록 받는 중")
        case .downloading(let file, let completed, let total):
            let mb = { (x: Int64) in String(format: "%.0f", Double(x) / 1_000_000) }
            status = .downloading(fraction: total > 0 ? Double(completed) / Double(total) : 0,
                                  detail: "\(mb(completed)) / \(mb(total)) MB · \((file as NSString).lastPathComponent)")
        case .verifying(let file):
            status = .verifying((file as NSString).lastPathComponent)
        }
    }

    private func load(directory: URL, settings: AppSettings, key: String) {
        status = .preparing(fraction: 0)
        let unit = settings.embedding.computeUnit
        let dimension = settings.embedding.dimension
        task = Task {
            do {
                let embedder = try await CoreMLEmbedder(
                    modelDirectory: directory,
                    cacheDirectory: directory.appending(path: "compiled"),
                    computeUnit: unit,
                    dimension: dimension,
                    key: key
                )
                try await embedder.prepare { fraction in
                    Task { @MainActor in
                        if case .preparing = self.status { self.status = .preparing(fraction: fraction) }
                    }
                }
                guard !Task.isCancelled, loadedKey == key else { return }
                self.embedder = embedder
                status = .ready
            } catch is CancellationError {
            } catch {
                status = .failed("임베딩 모델을 불러오지 못했습니다: \(error.localizedDescription)")
            }
        }
    }
}
