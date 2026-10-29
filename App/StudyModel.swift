import Foundation
import Observation
import PinpageCore

/// PDF 뷰어에 보여줄 위치.
struct ViewerTarget: Equatable {
    let documentURL: URL
    let fileName: String
    let pageIndex: Int
    /// 페이지 텍스트 안의 청크 범위 (OCR 청크는 nil)
    let chunkRange: NSRange?
    /// 청크 영역 (OCR 청크 강조와, 인용을 찾지 못했을 때 쓴다)
    let rects: [CGRect]
    /// 강조할 인용 문장들 (비어 있으면 청크 전체 강조, 예: 1단계 힌트)
    let quotes: [String]
    /// 같은 근거를 다시 눌러도 이동하도록 매번 바꾼다.
    let token = UUID()
}

/// 학습 화면 상태: 현재 문제, 질문과 답변, 단계별 힌트, 근거 위치.
@Observable @MainActor
final class StudyModel {
    struct Entry: Identifiable {
        enum Kind: Equatable {
            case question(String)
            case hint(level: Int)
        }
        let id = UUID()
        let kind: Kind
        var result: GroundedResult?
        var error: String?
    }

    /// 연습 문제. M4에서 자동으로 제시하기 전까지는 직접 입력한다.
    var problem = "" {
        didSet {
            if problem != oldValue { nextHintLevel = 1 }
        }
    }
    var question = ""
    private(set) var entries: [Entry] = []
    private(set) var nextHintLevel = 1
    private(set) var isBusy = false
    var viewerTarget: ViewerTarget?

    private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var hintLevelCount: Int { (try? app.promptTemplates.get().hints.count) ?? 0 }

    /// 답변할 수 없는 이유 (설정이 덜 됐거나 세트가 없음).
    var unavailableReason: String? {
        if case .failure(let error) = app.promptTemplates { return error.localizedDescription }
        guard app.libraryModel?.selectedSetId != nil else { return "학습 세트를 먼저 만들고 자료를 넣으세요." }
        if app.settings.chat.model.isEmpty { return "설정 탭에서 Chat API 주소와 모델을 지정하세요." }
        if (try? app.settings.chatEndpoint()) == nil { return "설정 탭에서 Chat API 주소를 확인하세요." }
        if app.settings.generation.extraBody == nil { return "설정 탭의 추가 요청 파라미터가 JSON 객체가 아닙니다." }
        return nil
    }

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        let problem = problem
        run(.question(text)) { engine, setId in
            try await engine.answer(question: text, problem: problem, setId: setId)
        }
    }

    func requestHint() {
        let problem = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !problem.isEmpty, nextHintLevel <= hintLevelCount else { return }
        let level = nextHintLevel
        run(.hint(level: level)) { engine, setId in
            try await engine.hint(level: level, problem: problem, question: nil, setId: setId)
        } onSuccess: { [weak self] in
            self?.nextHintLevel = level + 1
        }
    }

    func clear() {
        entries = []
        nextHintLevel = 1
        viewerTarget = nil
    }

    /// 같은 근거(청크)의 인용들을 하나로 묶는다. 순서는 처음 나온 순서.
    static func grouped(_ citations: [VerifiedCitation]) -> [[VerifiedCitation]] {
        var order: [Int] = []
        var groups: [Int: [VerifiedCitation]] = [:]
        for citation in citations {
            if groups[citation.source] == nil { order.append(citation.source) }
            groups[citation.source, default: []].append(citation)
        }
        return order.compactMap { groups[$0] }
    }

    /// 같은 근거의 인용들을 뷰어에 보여준다.
    func show(_ group: [VerifiedCitation]) {
        guard let library = app.libraryModel?.library, let first = group.first else { return }
        let chunk = first.hit.chunk
        viewerTarget = ViewerTarget(
            documentURL: library.fileURL(for: first.hit.document),
            fileName: first.hit.document.fileName,
            pageIndex: chunk.pageIndex,
            chunkRange: chunk.charStart.flatMap { start in chunk.charEnd.map { NSRange(location: start, length: $0 - start) } },
            rects: chunk.rects.map(\.cgRect),
            quotes: group.map(\.quote).filter { !$0.isEmpty }
        )
    }

    private func run(_ kind: Entry.Kind,
                     _ body: @escaping @Sendable (AnswerEngine, String) async throws -> GroundedResult,
                     onSuccess: (() -> Void)? = nil) {
        guard !isBusy else { return }
        if let reason = unavailableReason {
            entries.append(Entry(kind: kind, result: nil, error: reason))
            return
        }
        guard let setId = app.libraryModel?.selectedSetId, let engine = makeEngine() else { return }
        let entry = Entry(kind: kind)
        entries.append(entry)
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await body(engine, setId)
                update(entry.id) { $0.result = result }
                onSuccess?()
                // 첫 근거를 바로 보여준다.
                if let first = Self.grouped(result.citations).first { show(first) }
            } catch let error as LLMRequestError {
                update(entry.id) { $0.error = error.message }
            } catch {
                update(entry.id) { $0.error = error.localizedDescription }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private func makeEngine() -> AnswerEngine? {
        guard let library = app.libraryModel,
              let templates = try? app.promptTemplates.get(),
              let endpoint = try? app.settings.chatEndpoint()
        else { return nil }
        let settings = app.settings
        let client = OpenAIClient(
            endpoint: endpoint,
            timeoutSeconds: settings.network.requestTimeoutSeconds,
            retryPolicy: RetryPolicy(maxRetries: settings.network.maxRetries),
            recorder: app.callRecorder
        )
        return AnswerEngine(
            search: library.search, client: client, templates: templates,
            configuration: AnswerEngine.Configuration(settings: settings),
            embedder: app.embeddingManager.embedder, embeddingPrompts: app.embeddingManager.prompts
        )
    }
}
