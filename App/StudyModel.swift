import Foundation
import GRDB
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

/// 채점에서 빠진 요점의 근거 위치 (요점 문구는 정답이 드러나므로 보여주지 않는다).
struct MissedPoint: Identifiable {
    let id = UUID()
    let chunk: Chunk
    let document: Document
    let quote: String
    var label: String { CitationLabel.text(fileName: document.fileName, chunk: chunk) }
}

/// 학습 화면 상태: AI 연습 문제, 채점, 단계별 힌트, 자유 질문, 근거 위치. 모든 행동을 이벤트 로그에 남긴다.
@Observable @MainActor
final class StudyModel {
    struct Entry: Identifiable {
        enum Kind: Equatable {
            case question(String)
            case hint(level: Int)
        }
        let id = UUID()
        let requestId = UUID().uuidString
        let kind: Kind
        var result: GroundedResult?
        var error: String?
    }

    struct GradedAttempt: Identifiable {
        let attempt: ProblemAttempt
        let missed: [MissedPoint]
        var id: Int64 { attempt.id ?? -1 }
    }

    // 연습 문제
    private(set) var currentProblem: PracticeProblem?
    private(set) var problemNumber = 0
    private(set) var isGeneratingProblem = false
    private(set) var problemError: String?
    private(set) var attempts: [GradedAttempt] = []
    private(set) var isGrading = false
    var answerText = ""
    var selectedChoice: Int?
    private var prefetched: PracticeProblem?
    private var prefetchTask: Task<Void, Never>?
    private var shownAt = Date()
    private var practiceSetId: String?

    // 질문과 힌트
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
    var isSolved: Bool { attempts.last?.attempt.verdict == .correct }
    private var logger: EventLogger? { app.eventLogger }

    /// 답변·문제를 만들 수 없는 이유 (설정이 덜 됐거나 세트가 없음).
    var unavailableReason: String? {
        if case .failure(let error) = app.promptTemplates { return error.localizedDescription }
        guard app.libraryModel?.selectedSetId != nil else { return "학습 세트를 먼저 만들고 자료를 넣으세요." }
        if app.settings.chat.model.isEmpty { return "설정 탭에서 Chat API 주소와 모델을 지정하세요." }
        if (try? app.settings.chatEndpoint()) == nil { return "설정 탭에서 Chat API 주소를 확인하세요." }
        if app.settings.generation.extraBody == nil { return "설정 탭의 추가 요청 파라미터가 JSON 객체가 아닙니다." }
        return nil
    }

    // MARK: - 연습 문제

    /// 학습 화면이 열리거나 세트가 바뀌면 부른다. 풀던 문제가 없으면 다음 문제를 꺼낸다.
    func startPracticeIfNeeded() {
        let setId = app.libraryModel?.selectedSetId
        if practiceSetId != setId {
            practiceSetId = setId
            prefetchTask?.cancel()
            prefetched = nil
            currentProblem = nil
            problemNumber = 0
            attempts = []
            entries = []
            viewerTarget = nil
        }
        guard currentProblem == nil, !isGeneratingProblem, unavailableReason == nil else { return }
        nextProblem()
    }

    /// 다음 문제로 넘어간다. 풀지 않은 문제를 넘기면 건너뛰기로 기록한다.
    func nextProblem() {
        guard let setId = app.libraryModel?.selectedSetId else { return }
        if let current = currentProblem, !isSolved {
            logger?.log(.problemSkipped, ProblemSkippedPayload(
                problemId: current.id, attempts: attempts.count, elapsedMs: elapsedMs()))
            updateStatus(current.id, .skipped)
        }
        if let ready = prefetched {
            prefetched = nil
            show(ready)
            return
        }
        if let leftover = try? leftoverProblem(setId: setId) {
            show(leftover)
            return
        }
        generate(setId: setId) { [weak self] problem in self?.show(problem) }
    }

    func submitAnswer() {
        guard let problem = currentProblem, !isGrading, !isSolved, let grader = makeGrader() else { return }
        let answer = problem.type == .multipleChoice ? selectedChoice.map(String.init) ?? "" : answerText
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let elapsed = elapsedMs()
        let attemptNumber = attempts.count + 1
        isGrading = true
        problemError = nil
        Task {
            defer { isGrading = false }
            do {
                let attempt = try await grader.grade(problem, answer: answer)
                let missed = missedPoints(problem, attempt)
                attempts.append(GradedAttempt(attempt: attempt, missed: missed))
                logger?.log(.problemAnswered, ProblemAnsweredPayload(
                    problem: problem, attempt: attempt, attemptNumber: attemptNumber, elapsedMs: elapsed,
                    missed: missed.map { MissedPointPayload(chunk: $0.chunk, fileName: $0.document.fileName, quote: $0.quote) }))
                if attempt.verdict == .correct {
                    // 맞혔으면 다음 문제를 미리 만들어 둔다 (아직 안 만들었다면).
                    prefetchIfNeeded()
                }
            } catch {
                problemError = message(error)
                logger?.log(.error, ErrorPayload(context: "grade", message: message(error)))
            }
        }
    }

    private func show(_ problem: PracticeProblem) {
        currentProblem = problem
        problemNumber += 1
        attempts = []
        answerText = ""
        selectedChoice = nil
        nextHintLevel = 1
        problemError = nil
        shownAt = Date()
        updateStatus(problem.id, .shown, shownAt: shownAt)
        logger?.log(.problemShown, ProblemShownPayload(problem: problem, number: problemNumber))
        prefetchIfNeeded()
    }

    private func prefetchIfNeeded() {
        guard prefetched == nil, prefetchTask == nil, let setId = currentProblem?.setId else { return }
        prefetchTask = Task { [weak self] in
            guard let self, let generator = makeGenerator() else { return }
            defer { prefetchTask = nil }
            if let output = try? await generator.generate(setId: setId, types: app.settings.practice.problemTypes,
                                                          difficulty: app.settings.practice.difficulty),
               !Task.isCancelled, practiceSetId == setId {
                logGenerated(output)
                prefetched = output.problem
            }
        }
    }

    private func generate(setId: String, then: @escaping (PracticeProblem) -> Void) {
        guard let generator = makeGenerator() else { return }
        isGeneratingProblem = true
        problemError = nil
        let settings = app.settings.practice
        Task {
            defer { isGeneratingProblem = false }
            do {
                let output = try await generator.generate(setId: setId, types: settings.problemTypes, difficulty: settings.difficulty)
                logGenerated(output)
                guard practiceSetId == setId else { return }
                then(output.problem)
            } catch let error as ProblemGenerationError {
                if case .noValidProblem(let failures) = error {
                    logger?.log(.problemGenerationFailed, ProblemGenerationFailedPayload(setId: setId, failures: failures))
                }
                problemError = error.localizedDescription
            } catch {
                problemError = message(error)
                logger?.log(.error, ErrorPayload(context: "generate_problem", message: message(error)))
            }
        }
    }

    private func logGenerated(_ output: ProblemGenerator.Output) {
        if !output.failures.isEmpty {
            logger?.log(.problemGenerationFailed, ProblemGenerationFailedPayload(setId: output.problem.setId, failures: output.failures))
        }
        logger?.log(.problemGenerated, ProblemGeneratedPayload(problem: output.problem))
    }

    /// 앞서 만들어 두고 보여주지 않은 문제.
    private func leftoverProblem(setId: String) throws -> PracticeProblem? {
        try app.libraryModel?.library.database.writer.read { db in
            try PracticeProblem
                .filter(Column("setId") == setId && Column("status") == ProblemStatus.generated.rawValue)
                .order(Column("createdAt"))
                .fetchOne(db)
        }
    }

    private func updateStatus(_ id: String, _ status: ProblemStatus, shownAt: Date? = nil) {
        try? app.libraryModel?.library.database.writer.write { db in
            guard var problem = try PracticeProblem.fetchOne(db, key: id) else { return }
            problem.status = status
            if let shownAt { problem.shownAt = shownAt }
            try problem.update(db)
        }
    }

    private func missedPoints(_ problem: PracticeProblem, _ attempt: ProblemAttempt) -> [MissedPoint] {
        guard let library = app.libraryModel?.library else { return [] }
        var seen = Set<Int64>()
        return attempt.missedKeyPoints.compactMap { index -> MissedPoint? in
            let point = problem.keyPoints[index]
            guard seen.insert(point.chunkId).inserted,
                  let chunk = try? library.database.writer.read({ db in try Chunk.fetchOne(db, key: point.chunkId) }),
                  let document = try? library.document(id: chunk.documentId) else { return nil }
            return MissedPoint(chunk: chunk, document: document, quote: point.quote)
        }
    }

    private func elapsedMs() -> Int { Int(Date().timeIntervalSince(shownAt) * 1000) }

    // MARK: - 질문과 힌트

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        let problem = currentProblem?.promptText
        run(.question(text)) { engine, setId in
            try await engine.answer(question: text, problem: problem, setId: setId)
        }
    }

    func requestHint() {
        guard let problem = currentProblem, nextHintLevel <= hintLevelCount else { return }
        let level = nextHintLevel
        let text = problem.promptText
        run(.hint(level: level)) { engine, setId in
            try await engine.hint(level: level, problem: text, question: nil, setId: setId)
        } onSuccess: { [weak self] in
            self?.nextHintLevel = level + 1
        }
    }

    func clearConversation() {
        entries = []
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
    func show(_ group: [VerifiedCitation], requestId: String?) {
        guard let first = group.first else { return }
        open(chunk: first.hit.chunk, document: first.hit.document, quotes: group.map(\.quote), requestId: requestId)
    }

    func show(_ missed: MissedPoint) {
        open(chunk: missed.chunk, document: missed.document, quotes: [missed.quote], requestId: nil)
    }

    private func open(chunk: Chunk, document: Document, quotes: [String], requestId: String?) {
        guard let library = app.libraryModel?.library else { return }
        viewerTarget = ViewerTarget(
            documentURL: library.fileURL(for: document),
            fileName: document.fileName,
            pageIndex: chunk.pageIndex,
            chunkRange: chunk.charStart.flatMap { start in chunk.charEnd.map { NSRange(location: start, length: $0 - start) } },
            rects: chunk.rects.map(\.cgRect),
            quotes: quotes.filter { !$0.isEmpty }
        )
        logger?.log(.citationOpened, CitationOpenedPayload(requestId: requestId, problemId: currentProblem?.id,
                                                           chunk: chunk, fileName: document.fileName))
    }

    private func run(_ kind: Entry.Kind,
                     _ body: @escaping @Sendable (AnswerEngine, String) async throws -> GroundedResult,
                     onSuccess: (() -> Void)? = nil) {
        guard !isBusy else { return }
        var entry = Entry(kind: kind)
        if let reason = unavailableReason {
            entry.error = reason
            entries.append(entry)
            return
        }
        guard let setId = app.libraryModel?.selectedSetId, let engine = makeEngine() else { return }
        entries.append(entry)
        isBusy = true
        let problemId = currentProblem?.id
        let problem = currentProblem?.promptText
        let startedAt = Date()
        switch kind {
        case .question(let text):
            logger?.log(.questionAsked, RequestPayload(requestId: entry.requestId, setId: setId, problemId: problemId,
                                                       question: text, hintLevel: nil))
        case .hint(let level):
            logger?.log(.hintRequested, RequestPayload(requestId: entry.requestId, setId: setId, problemId: problemId,
                                                       question: nil, hintLevel: level))
        }
        let receivedType: EventType = if case .hint = kind { .hintReceived } else { .answerReceived }
        let embedderKey = app.embeddingManager.embedder?.key
        Task {
            defer { isBusy = false }
            do {
                let result = try await body(engine, setId)
                update(entry.id) { $0.result = result }
                logger?.log(receivedType, GroundedPayload(requestId: entry.requestId, setId: setId, problemId: problemId,
                                                          result: result, embedderKey: embedderKey))
                onSuccess?()
                // 첫 근거를 바로 보여준다.
                if let first = Self.grouped(result.citations).first { show(first, requestId: entry.requestId) }
            } catch {
                let text = message(error)
                update(entry.id) { $0.error = text }
                let level: Int? = if case .hint(let level) = kind { level } else { nil }
                let questionText: String = if case .question(let q) = kind { q } else { "" }
                logger?.log(receivedType, GroundedPayload(
                    requestId: entry.requestId, setId: setId, problemId: problemId, kind: level == nil ? "answer" : "hint",
                    hintLevel: level, question: questionText, problem: problem, error: text, model: app.settings.chat.model,
                    templateFingerprint: engine.templates.fingerprint, startedAt: startedAt))
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private func message(_ error: Error) -> String {
        (error as? LLMRequestError)?.message ?? error.localizedDescription
    }

    // MARK: - 엔진

    private func makeClient() -> OpenAIClient? {
        guard let endpoint = try? app.settings.chatEndpoint() else { return nil }
        let settings = app.settings
        return OpenAIClient(endpoint: endpoint, timeoutSeconds: settings.network.requestTimeoutSeconds,
                            retryPolicy: RetryPolicy(maxRetries: settings.network.maxRetries), recorder: app.callRecorder)
    }

    private func makeEngine() -> AnswerEngine? {
        guard let library = app.libraryModel, let templates = try? app.promptTemplates.get(), let client = makeClient() else { return nil }
        return AnswerEngine(search: library.search, client: client, templates: templates,
                            configuration: AnswerEngine.Configuration(settings: app.settings),
                            embedder: app.embeddingManager.embedder, embeddingPrompts: app.embeddingManager.prompts)
    }

    private func makeGenerator() -> ProblemGenerator? {
        guard unavailableReason == nil, let library = app.libraryModel, let templates = try? app.promptTemplates.get(),
              let client = makeClient() else { return nil }
        return ProblemGenerator(database: library.library.database, client: client, templates: templates,
                                request: StructuredRequest(settings: app.settings, temperature: app.settings.practice.generationTemperature))
    }

    private func makeGrader() -> ProblemGrader? {
        guard let library = app.libraryModel, let templates = try? app.promptTemplates.get(), let client = makeClient() else { return nil }
        return ProblemGrader(database: library.library.database, client: client, templates: templates,
                             request: StructuredRequest(settings: app.settings))
    }
}
