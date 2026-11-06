import AppKit
import Foundation
import Observation
import PinpageCore
import UniformTypeIdentifiers

/// 실험 세션 상태: 시작, 단계 진행, 퀴즈 응시, 경과 시간, 강제 종료 뒤 복구. 모든 단계 변화를 이벤트 로그에 남긴다.
///
/// 경과 시간은 1초마다 더하고 5초마다(그리고 단계가 바뀔 때, 앱이 뒤로 가거나 끝날 때) DB에 저장한다.
/// 앱이 강제 종료돼도 잃는 시간은 최대 5초다.
@Observable @MainActor
final class SessionModel {
    /// 끝난 세션 요약 (확인을 누르면 시작 화면으로 돌아간다).
    struct Summary {
        let session: ExperimentSession
        let result: QuizResult?
        let checkpointAttempts: Int
    }

    static let saveEveryTicks = 5

    // 진행 중인 세션
    private(set) var session: ExperimentSession?
    private(set) var quizFile: QuizFile?
    private(set) var quizRecord: QuizSetRecord?
    /// 지금 풀고 있는 응시
    private(set) var attempt: QuizAttempt?
    /// 문제 id → 답. 고칠 때마다 저장한다.
    var responses: [String: String] = [:] {
        didSet { if responses != oldValue { scheduleResponseSave() } }
    }
    /// 마지막 체크포인트 결과 (떨어진 뒤 학습 화면에 총점만 보여준다)
    private(set) var lastCheckpoint: QuizResult?
    private(set) var checkpointAttempts = 0
    private(set) var summary: Summary?
    /// 화면에 보여줄 누적 시간 (1초마다 바뀐다)
    private(set) var times = StageTimes()
    /// 사전 퀴즈를 낸 직후 등 한 번 보여줄 안내
    var notice: String?
    var errorMessage: String?

    // 시작 화면 입력
    var participantId = ""
    var condition: ExperimentCondition = .tool
    var kind: SessionKind = .learning
    var setId: String?
    var quizSetId: String?
    private(set) var quizSets: [QuizSetRecord] = []
    private(set) var pastSessions: [ExperimentSession] = []

    private let store: SessionStore?
    private var timer = SessionTimer()
    private var isForeground = true
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var ticksSinceSave = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var responseSaveTask: Task<Void, Never>?
    private unowned let app: AppModel

    init(app: AppModel, store: SessionStore?) {
        self.app = app
        self.store = store
        reloadLists()
        restore()
    }

    var isActive: Bool { session != nil }
    private var logger: EventLogger? { app.eventLogger }

    /// 도구 조건 학습 세션의 자료 세트 (연습 문제와 질문에 쓴다).
    var studySetId: String? {
        guard let session, session.kind == .learning else { return nil }
        return session.setId
    }

    var currentQuiz: Quiz? {
        guard let attempt else { return nil }
        return quizFile?.quiz(attempt.quizKind)
    }

    // MARK: - 시작 화면

    func reloadLists() {
        quizSets = (try? store?.quizSets()) ?? []
        pastSessions = (try? store?.sessions(limit: 30)) ?? []
        if quizSetId == nil || !quizSets.contains(where: { $0.id == quizSetId }) { quizSetId = quizSets.first?.id }
        if setId == nil { setId = app.libraryModel?.selectedSetId }
    }

    func importQuizFile() {
        let panel = NSOpenPanel()
        panel.title = "퀴즈 파일 불러오기"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        do {
            let record = try store.importQuiz(data: try Data(contentsOf: url), fileName: url.lastPathComponent)
            reloadLists()
            quizSetId = record.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedQuizFile: QuizFile? {
        guard let id = quizSetId else { return nil }
        return try? quizSets.first { $0.id == id }?.file()
    }

    /// 시작을 막는 문제들.
    var startBlockers: [String] {
        var issues: [String] = []
        let id = participantId.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            issues.append("참가자 ID를 입력하세요.")
        } else if !SessionStore.isValidParticipantId(id) {
            issues.append(SessionError.invalidParticipantId.localizedDescription)
        }
        if let file = selectedQuizFile {
            if file.quiz(kind.mainQuiz) == nil { issues.append(SessionError.missingQuiz(kind.mainQuiz).localizedDescription) }
        } else {
            issues.append("퀴즈 파일을 불러오세요.")
        }
        if kind == .learning {
            if setId == nil {
                issues.append("학습 세트를 고르세요.")
            } else if indexedDocuments(setId: setId).isEmpty {
                issues.append(SessionError.noMaterials.localizedDescription)
            }
            if condition == .tool, let reason = app.studyModel.configurationIssue {
                issues.append("도구 조건에는 AI 연결이 필요합니다: \(reason)")
            }
        }
        return issues
    }

    /// 시작은 되지만 알아 둘 점.
    var startWarnings: [String] {
        var warnings: [String] = []
        if kind == .learning, selectedQuizFile != nil, selectedQuizFile?.quiz(.pre) == nil {
            warnings.append("퀴즈 파일에 사전 퀴즈가 없어 바로 학습을 시작합니다. 도구 조건의 연습 문제 난이도는 설정값(\(app.settings.practice.difficulty))을 씁니다.")
        }
        if kind == .learning, condition == .tool, app.settings.embedding.mode != .off, app.embeddingManager.embedder == nil {
            warnings.append("임베딩 모델이 준비되지 않아 키워드 검색(BM25)만으로 근거를 찾습니다.")
        }
        if kind == .learning, let setId, !(app.libraryModel?.outdatedDocuments.isEmpty ?? true),
           app.libraryModel?.selectedSetId == setId {
            warnings.append("현재 설정과 다르게 색인된 자료가 있습니다. 학습 세트 탭에서 다시 색인하세요.")
        }
        return warnings
    }

    func indexedDocuments(setId: String?) -> [Document] {
        guard let setId, let library = app.libraryModel?.library else { return [] }
        return ((try? library.documents(inSet: setId)) ?? [])
            .map(\.document)
            .filter { $0.kind == .pdf && $0.status == .indexed }
    }

    func start() {
        guard let store, let quizSetId, startBlockers.isEmpty else { return }
        do {
            let (started, attempt) = try store.start(
                participantId: participantId, condition: condition, kind: kind, setId: setId,
                quizSetId: quizSetId, defaultDifficulty: app.settings.practice.difficulty)
            guard let record = try store.quizSet(id: quizSetId) else { throw SessionError.quizSetNotFound }
            let file = try record.file()
            begin(started, record: record, file: file)
            let setName = started.setId.flatMap { id in app.libraryModel?.sets.first { $0.id == id }?.name }
            logger?.log(.sessionStarted, SessionStartedPayload(
                session: started, setName: setName, documents: indexedDocuments(setId: started.setId),
                quizSet: QuizSetPayload(record: record, file: file), settings: app.settings,
                embedderKey: app.embeddingManager.embedder?.key,
                templateFingerprint: try? app.promptTemplates.get().fingerprint))
            if let difficulty = started.practiceDifficulty {
                logger?.log(.practiceDifficultySet, PracticeDifficultySetPayload(
                    difficulty: difficulty, source: "settings", preQuizRatio: nil, policy: policy))
            }
            if let attempt { open(attempt, resumed: false) }
            participantId = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 복구

    /// 앱을 열 때 진행 중인 세션이 있으면 그 단계로 돌아간다.
    private func restore() {
        guard let store else { return }
        do {
            guard let active = try store.activeSession() else { return }
            let resumed = try store.resume(active)
            guard let record = try store.quizSet(id: active.quizSetId) else { throw SessionError.quizSetNotFound }
            let file = try record.file()
            begin(resumed.session, record: record, file: file)
            logger?.log(.sessionResumed, SessionResumedPayload(session: resumed.session, downtimeMs: resumed.downtimeMs,
                                                               closedCleanly: resumed.closedCleanly))
            let attempts = try store.attempts(sessionId: active.id)
            checkpointAttempts = attempts.filter { $0.quizKind == .checkpoint && $0.submittedAt != nil }.count
            if let reopened = try store.openOrCreateAttempt(for: resumed.session) {
                open(reopened.attempt, resumed: reopened.resumed)
            }
            if !resumed.closedCleanly {
                notice = "앱이 예기치 않게 종료되어 진행 중이던 세션을 이어서 엽니다. 경과 시간은 마지막 저장 시점부터 이어집니다."
            }
        } catch {
            errorMessage = "진행 중인 세션을 복구하지 못했습니다: \(error.localizedDescription)"
            logger?.log(.error, ErrorPayload(context: "session_restore", message: error.localizedDescription))
        }
    }

    private func begin(_ started: ExperimentSession, record: QuizSetRecord, file: QuizFile) {
        session = started
        quizRecord = record
        quizFile = file
        lastCheckpoint = nil
        checkpointAttempts = 0
        summary = nil
        notice = nil
        logger?.context = EventLogger.Context(sessionId: started.id, participantId: started.participantId)
        if let setId = started.setId, started.kind == .learning { app.libraryModel?.selectedSetId = setId }
        timer = SessionTimer(times: started.times)
        times = started.times
        isForeground = NSApplication.shared.isActive
        startClock()
    }

    // MARK: - 퀴즈

    private func open(_ attempt: QuizAttempt, resumed: Bool) {
        self.attempt = attempt
        responseSaveTask?.cancel()
        responses = attempt.responses
        responseSaveTask?.cancel()
        if let quiz = quizFile?.quiz(attempt.quizKind), let record = quizRecord {
            logger?.log(.quizStarted, QuizStartedPayload(attempt: attempt, quiz: quiz, quizSetSha256: record.sha256, resumed: resumed))
        }
    }

    /// 학습 중 체크포인트 퀴즈를 시작한다 (자료와 AI 도우미를 숨긴다).
    func beginCheckpoint() {
        guard let store, var current = session, current.phase == .studying else { return }
        tick()
        current.times = timer.times
        do {
            let (updated, attempt) = try store.beginCheckpoint(current)
            session = updated
            notice = nil
            ticksSinceSave = 0
            open(attempt, resumed: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitQuiz() {
        guard let store, var current = session, let attempt, let attemptId = attempt.id, let quiz = currentQuiz else { return }
        responseSaveTask?.cancel()
        tick()
        current.times = timer.times
        do {
            let submission = try store.submit(attemptId: attemptId, responses: responses, session: current, quiz: quiz,
                                              threshold: app.settings.learning.quizPassThreshold, policy: policy)
            logger?.log(.quizSubmitted, QuizSubmittedPayload(attempt: submission.attempt, result: submission.result))
            session = submission.session
            self.attempt = nil
            responses = [:]
            responseSaveTask?.cancel()
            ticksSinceSave = 0
            switch submission.outcome {
            case .preQuizDone(let difficulty):
                if let difficulty {
                    logger?.log(.practiceDifficultySet, PracticeDifficultySetPayload(
                        difficulty: difficulty, source: "pre_quiz", preQuizRatio: submission.result.ratio, policy: policy))
                }
                notice = "사전 퀴즈를 제출했습니다. 이제 학습을 시작하세요. 준비가 되면 위의 [체크포인트 퀴즈]를 응시합니다."
            case .checkpointFailed:
                checkpointAttempts += 1
                lastCheckpoint = submission.result
                notice = nil
            case .checkpointPassed:
                checkpointAttempts += 1
                finish(submission.session, result: submission.result)
            case .examCompleted:
                finish(submission.session, result: submission.result)
            }
        } catch {
            errorMessage = error.localizedDescription
            logger?.log(.error, ErrorPayload(context: "quiz_submit", message: error.localizedDescription))
        }
    }

    private func scheduleResponseSave() {
        guard let attemptId = attempt?.id, let store else { return }
        let snapshot = responses
        responseSaveTask?.cancel()
        responseSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                try store.saveResponses(attemptId: attemptId, responses: snapshot)
            } catch {
                errorMessage = "답을 저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 끝내기

    func abandon() {
        guard let store, var current = session else { return }
        responseSaveTask?.cancel()
        if let attemptId = attempt?.id { try? store.saveResponses(attemptId: attemptId, responses: responses) }
        tick()
        current.times = timer.times
        do {
            finish(try store.abandon(current), result: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish(_ ended: ExperimentSession, result: QuizResult?) {
        stopClock()
        logger?.log(.sessionEnded, SessionEndedPayload(session: ended, checkpointAttempts: checkpointAttempts))
        logger?.context = EventLogger.Context()
        summary = Summary(session: ended, result: result, checkpointAttempts: checkpointAttempts)
        times = ended.times
        session = nil
        attempt = nil
        quizFile = nil
        quizRecord = nil
        lastCheckpoint = nil
        notice = nil
        reloadLists()
    }

    func dismissSummary() {
        summary = nil
    }

    private var policy: DifficultyPolicy { DifficultyPolicy(settings: app.settings.learning) }

    // MARK: - 시간

    private func startClock() {
        timer.start(at: ProcessInfo.processInfo.systemUptime)
        ticksSinceSave = 0
        tickTimer?.invalidate()
        let tickTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(save: true) }
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        self.tickTimer = tickTimer
        // 앱이 뒤에 있어도 시간 저장 타이머가 늦어지지 않게 App Nap을 끈다 (Mac 잠자기는 막지 않는다).
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "실험 세션 경과 시간 측정")
        }
    }

    private func stopClock() {
        timer.stop(at: ProcessInfo.processInfo.systemUptime, stage: session?.phase.stage, foreground: isForeground)
        tickTimer?.invalidate()
        tickTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// 지난 tick부터 지금까지를 현재 단계에 더한다.
    private func tick(save: Bool = false) {
        guard let stage = session?.phase.stage else { return }
        timer.tick(at: ProcessInfo.processInfo.systemUptime, stage: stage, foreground: isForeground)
        times = timer.times
        guard save else { return }
        ticksSinceSave += 1
        if ticksSinceSave >= Self.saveEveryTicks { saveTimes() }
    }

    private func saveTimes() {
        guard let store, var current = session else { return }
        current.times = timer.times
        do {
            session = try store.save(current)
            ticksSinceSave = 0
        } catch {
            errorMessage = "경과 시간을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 앱 상태 변화 (AppModel이 알려준다)

    func appDidResignActive() {
        tick()
        isForeground = false
        saveTimes()
    }

    func appDidBecomeActive() {
        tick()
        isForeground = true
    }

    func systemWillSleep() {
        guard isActive else { return }
        timer.stop(at: ProcessInfo.processInfo.systemUptime, stage: session?.phase.stage, foreground: isForeground)
        times = timer.times
        saveTimes()
    }

    func systemDidWake() {
        guard isActive else { return }
        timer.start(at: ProcessInfo.processInfo.systemUptime)
    }

    func appWillTerminate() {
        guard let store, var current = session else { return }
        if let attemptId = attempt?.id { try? store.saveResponses(attemptId: attemptId, responses: responses) }
        tick()
        current.times = timer.times
        try? store.markClosedCleanly(current)
    }
}
