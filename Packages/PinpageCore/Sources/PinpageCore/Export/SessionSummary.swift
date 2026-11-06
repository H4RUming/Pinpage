import Foundation

/// sessions.csv 한 줄: 세션 하나의 요약.
///
/// 세션 기록(DB)과 그 세션의 이벤트로 계산한다. 열 구성은 데이터와 관계없이 항상 같다.
/// - 횟수 열은 항상 숫자 (해당 없으면 0)
/// - 해당 없는 점수·시각 열은 빈 칸 (예: 학습 세션의 시험 점수, 대조 조건의 연습 난이도)
public struct SessionSummary: Equatable, Sendable {
    public struct Score: Equatable, Sendable {
        public let earned: Int
        public let total: Int
        public var ratio: Double { total > 0 ? Double(earned) / Double(total) : 0 }

        public init(earned: Int, total: Int) {
            self.earned = earned
            self.total = total
        }

        init?(_ attempt: QuizAttempt?) {
            guard let attempt, let earned = attempt.earned, let total = attempt.total else { return nil }
            self.init(earned: earned, total: total)
        }
    }

    /// 힌트 단계 열 수 (설정에서 고를 수 있는 최대 단계). 설정이 3단계여도 열은 이만큼 둔다.
    public static let maxHintLevel = SettingsLimits.hintLevels.upperBound

    // 식별
    public var participantId: String
    public var sessionId: String
    public var condition: String
    public var sessionKind: String
    public var setName: String?
    public var quizId: String?
    public var quizSha256: String?
    /// 세션을 진행한 앱 버전
    public var appVersion: String?
    public var model: String?
    public var settingsHash: String?
    public var exportedAt: Date

    // 시각
    public var startedAt: Date
    public var endedAt: Date?
    /// passed, completed, abandoned, in_progress
    public var endReason: String

    // 시간
    public var times: StageTimes
    public var timeToPassMs: Int?
    public var downtimeMs: Int
    public var resumeCount: Int
    public var uncleanExitCount: Int

    // 퀴즈
    public var preQuiz: Score?
    public var practiceDifficulty: Int?
    public var checkpointAttempts: Int
    public var checkpointPassed: Bool?
    public var checkpointLast: Score?
    public var exam: Score?
    public var examPassed: Bool?

    // 도구 사용
    public var questionsAsked: Int
    public var notInMaterials: Int
    /// [1단계 요청 수, 2단계, …] (maxHintLevel개)
    public var hintRequests: [Int]
    public var practiceShown: Int
    public var practiceSubmissions: Int
    public var practiceCorrect: Int
    public var practiceSkipped: Int
    public var citationsOpened: Int

    // 자료 뷰어
    public var documentsOpened: Int
    public var documentSearches: Int

    // 앱과 서버
    public var appPauses: Int
    public var llmCalls: Int
    public var llmFailures: Int
    public var llmLatencyMsMedian: Int?

    /// - Parameters:
    ///   - events: 이 세션의 이벤트 (sessionId가 같은 것, 순번 순)
    ///   - attempts: 이 세션의 퀴즈 응시 (id 순)
    ///   - setName: 학습 세트 이름 (session_started 이벤트에 없을 때 쓴다)
    public init(session: ExperimentSession, events: [EventRecord], attempts: [QuizAttempt], quizSet: QuizSetRecord?,
                setName: String?, exportedAt: Date) {
        let decoder = JSONDecoder()
        let started = events.first { $0.type == EventType.sessionStarted.rawValue }
        let startedInfo = started.flatMap { $0.decode(StartedInfo.self, decoder) }
        func count(_ type: EventType) -> Int { events.filter { $0.type == type.rawValue }.count }
        func payloads<T: Decodable>(_ type: EventType, as: T.Type) -> [T] {
            events.filter { $0.type == type.rawValue }.compactMap { $0.decode(T.self, decoder) }
        }

        participantId = session.participantId
        sessionId = session.id
        condition = session.condition.rawValue
        sessionKind = session.kind.rawValue
        self.setName = startedInfo?.setName ?? setName
        quizId = quizSet?.quizId ?? startedInfo?.quizSet?.quizId
        quizSha256 = quizSet?.sha256 ?? startedInfo?.quizSet?.sha256
        appVersion = started?.appVersion ?? events.first?.appVersion
        model = startedInfo?.model
        settingsHash = startedInfo?.experimentSettingsHash
        self.exportedAt = exportedAt

        startedAt = session.startedAt
        endedAt = session.endedAt
        endReason = session.endReason ?? (session.phase.isActive ? "in_progress" : session.phase.rawValue)

        times = session.times
        timeToPassMs = session.kind == .learning && session.endReason == "passed" ? session.times.learningMs : nil
        let resumes = payloads(.sessionResumed, as: ResumedInfo.self)
        downtimeMs = resumes.reduce(0) { $0 + ($1.downtimeMs ?? 0) }
        resumeCount = count(.sessionResumed)
        uncleanExitCount = resumes.filter { $0.closedCleanly == false }.count

        let submittedAttempts = attempts.filter { $0.submittedAt != nil }
        func submitted(_ kind: QuizKind) -> [QuizAttempt] { submittedAttempts.filter { $0.quizKind == kind } }
        preQuiz = Score(submitted(.pre).first)
        practiceDifficulty = session.practiceDifficulty
        if session.kind == .learning {
            let checkpoints = submitted(.checkpoint)
            checkpointAttempts = checkpoints.count
            checkpointPassed = checkpoints.contains { $0.passed == true }
            checkpointLast = Score(checkpoints.last)
            exam = nil
            examPassed = nil
        } else {
            checkpointAttempts = 0
            checkpointPassed = nil
            checkpointLast = nil
            let examAttempt = submitted(session.kind.mainQuiz).first
            exam = Score(examAttempt)
            examPassed = examAttempt?.passed
        }

        questionsAsked = count(.questionAsked)
        notInMaterials = payloads(.answerReceived, as: StatusInfo.self).filter { $0.status == GroundedStatus.notInMaterials.rawValue }.count
        let levels = payloads(.hintRequested, as: HintInfo.self).compactMap(\.hintLevel)
        hintRequests = (1...Self.maxHintLevel).map { level in levels.filter { $0 == level }.count }
        practiceShown = count(.problemShown)
        let answers = payloads(.problemAnswered, as: VerdictInfo.self)
        practiceSubmissions = count(.problemAnswered)
        practiceCorrect = answers.filter { $0.verdict == Verdict.correct.rawValue }.count
        practiceSkipped = count(.problemSkipped)
        citationsOpened = count(.citationOpened)

        documentsOpened = count(.documentOpened)
        documentSearches = count(.documentSearched)

        appPauses = count(.appPause)
        let chatCalls = payloads(.llmCall, as: CallInfo.self).filter { $0.operation == LLMOperation.chat.rawValue }
        llmCalls = chatCalls.count
        llmFailures = chatCalls.filter { $0.outcome == LLMCallRecord.Outcome.failure.rawValue }.count
        llmLatencyMsMedian = Self.median(chatCalls.filter { $0.outcome == LLMCallRecord.Outcome.success.rawValue }.compactMap(\.latencyMs))
    }

    /// 가운데 값. 개수가 짝수면 가운데 두 값의 평균(반올림).
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded())
    }

    // MARK: - 열

    public static let columns: [CSVColumn<SessionSummary>] = {
        typealias Column = CSVColumn<SessionSummary>
        var columns: [Column] = [
            Column("participant_id") { $0.participantId },
            Column("session_id") { $0.sessionId },
            Column("condition") { $0.condition },
            Column("session_kind") { $0.sessionKind },
            Column("set_name") { $0.setName ?? "" },
            Column("quiz_id") { $0.quizId ?? "" },
            Column("quiz_sha256") { $0.quizSha256 ?? "" },
            Column("app_version") { $0.appVersion ?? "" },
            Column("model") { $0.model ?? "" },
            Column("settings_hash") { $0.settingsHash ?? "" },
            Column("exported_at") { CSV.time($0.exportedAt) },

            Column("started_at") { CSV.time($0.startedAt) },
            Column("ended_at") { CSV.time($0.endedAt) },
            Column("end_reason") { $0.endReason },

            Column("pre_quiz_ms") { CSV.int($0.times.preQuizMs) },
            Column("study_ms") { CSV.int($0.times.studyMs) },
            Column("quiz_ms") { CSV.int($0.times.quizMs) },
            Column("background_ms") { CSV.int($0.times.backgroundMs) },
            Column("time_to_pass_ms") { CSV.int($0.timeToPassMs) },
            Column("downtime_ms") { CSV.int($0.downtimeMs) },
            Column("resume_count") { CSV.int($0.resumeCount) },
            Column("unclean_exit_count") { CSV.int($0.uncleanExitCount) },

            Column("pre_quiz_earned") { CSV.int($0.preQuiz?.earned) },
            Column("pre_quiz_total") { CSV.int($0.preQuiz?.total) },
            Column("pre_quiz_ratio") { CSV.ratio($0.preQuiz?.ratio) },
            Column("practice_difficulty") { CSV.int($0.practiceDifficulty) },

            Column("checkpoint_attempts") { CSV.int($0.checkpointAttempts) },
            Column("checkpoint_passed") { CSV.bool($0.checkpointPassed) },
            Column("checkpoint_last_earned") { CSV.int($0.checkpointLast?.earned) },
            Column("checkpoint_last_total") { CSV.int($0.checkpointLast?.total) },
            Column("checkpoint_last_ratio") { CSV.ratio($0.checkpointLast?.ratio) },

            Column("exam_earned") { CSV.int($0.exam?.earned) },
            Column("exam_total") { CSV.int($0.exam?.total) },
            Column("exam_ratio") { CSV.ratio($0.exam?.ratio) },
            Column("exam_passed") { CSV.bool($0.examPassed) },

            Column("questions_asked") { CSV.int($0.questionsAsked) },
            Column("not_in_materials") { CSV.int($0.notInMaterials) },
        ]
        for level in 1...maxHintLevel {
            columns.append(Column("hint_level_\(level)") { CSV.int($0.hintRequests[level - 1]) })
        }
        columns += [
            Column("practice_shown") { CSV.int($0.practiceShown) },
            Column("practice_submissions") { CSV.int($0.practiceSubmissions) },
            Column("practice_correct") { CSV.int($0.practiceCorrect) },
            Column("practice_skipped") { CSV.int($0.practiceSkipped) },
            Column("citations_opened") { CSV.int($0.citationsOpened) },

            Column("documents_opened") { CSV.int($0.documentsOpened) },
            Column("document_searches") { CSV.int($0.documentSearches) },

            Column("app_pauses") { CSV.int($0.appPauses) },
            Column("llm_calls") { CSV.int($0.llmCalls) },
            Column("llm_failures") { CSV.int($0.llmFailures) },
            Column("llm_latency_ms_median") { CSV.int($0.llmLatencyMsMedian) },
        ]
        return columns
    }()
}

/// quiz_items.csv 한 줄: 제출한 퀴즈 응시의 문제 하나.
public struct QuizItemRow: Equatable, Sendable {
    public var participantId: String
    public var sessionId: String
    public var condition: String
    public var sessionKind: String
    public var quizId: String?
    public var quizKind: String
    public var attemptNumber: Int
    /// 퀴즈 안에서 몇 번째 문제인지 (1부터)
    public var questionNumber: Int
    public var item: QuizItemResult
    public var attemptActiveMs: Int?
    public var submittedAt: Date?

    /// 제출한 응시마다 문제별 행을 만든다.
    /// 채점 결과는 제출할 때 남긴 quiz_submitted 이벤트를 그대로 쓰고, 이벤트가 없으면 퀴즈 파일로 다시 채점한다(같은 코드).
    public static func rows(session: ExperimentSession, events: [EventRecord], attempts: [QuizAttempt],
                            quizSet: QuizSetRecord?) -> [QuizItemRow] {
        let decoder = JSONDecoder()
        let submittedEvents = events.filter { $0.type == EventType.quizSubmitted.rawValue }
            .compactMap { $0.decode(QuizSubmittedPayload.self, decoder) }
        let file = try? quizSet?.file()
        return attempts.filter { $0.submittedAt != nil }.flatMap { attempt -> [QuizItemRow] in
            let logged = submittedEvents.last { $0.quizKind == attempt.quizKind.rawValue && $0.attemptNumber == attempt.attemptNumber }
            let items = logged?.items
                ?? file?.quiz(attempt.quizKind).map { QuizScorer.score($0, responses: attempt.responses, threshold: 0).items }
                ?? []
            return items.enumerated().map { index, item in
                QuizItemRow(participantId: session.participantId, sessionId: session.id, condition: session.condition.rawValue,
                            sessionKind: session.kind.rawValue, quizId: quizSet?.quizId, quizKind: attempt.quizKind.rawValue,
                            attemptNumber: attempt.attemptNumber, questionNumber: index + 1, item: item,
                            attemptActiveMs: attempt.activeMs, submittedAt: attempt.submittedAt)
            }
        }
    }

    public static let columns: [CSVColumn<QuizItemRow>] = [
        CSVColumn("participant_id") { $0.participantId },
        CSVColumn("session_id") { $0.sessionId },
        CSVColumn("condition") { $0.condition },
        CSVColumn("session_kind") { $0.sessionKind },
        CSVColumn("quiz_id") { $0.quizId ?? "" },
        CSVColumn("quiz_kind") { $0.quizKind },
        CSVColumn("attempt_number") { CSV.int($0.attemptNumber) },
        CSVColumn("question_number") { CSV.int($0.questionNumber) },
        CSVColumn("question_id") { $0.item.questionId },
        CSVColumn("question_type") { $0.item.type },
        CSVColumn("response") { $0.item.response ?? "" },
        CSVColumn("correct") { CSV.bool($0.item.correct) },
        CSVColumn("points") { CSV.int($0.item.points) },
        CSVColumn("earned") { CSV.int($0.item.earned) },
        CSVColumn("attempt_active_ms") { CSV.int($0.attemptActiveMs) },
        CSVColumn("submitted_at") { CSV.time($0.submittedAt) },
    ]
}

// MARK: - 요약에 필요한 이벤트 내용만 읽는다
// 필요한 키만 읽으므로 이벤트에 다른 키가 늘어나도 요약은 그대로 계산된다.

private struct StartedInfo: Decodable {
    struct QuizInfo: Decodable {
        let quizId: String?
        let sha256: String?
    }

    let setName: String?
    let model: String?
    let experimentSettingsHash: String?
    let quizSet: QuizInfo?
}

private struct ResumedInfo: Decodable {
    let downtimeMs: Int?
    let closedCleanly: Bool?
}

private struct StatusInfo: Decodable {
    let status: String?
}

private struct HintInfo: Decodable {
    let hintLevel: Int?
}

private struct VerdictInfo: Decodable {
    let verdict: String?
}

private struct CallInfo: Decodable {
    let operation: String?
    let outcome: String?
    let latencyMs: Int?
}

extension EventRecord {
    func decode<T: Decodable>(_ type: T.Type, _ decoder: JSONDecoder) -> T? {
        try? decoder.decode(T.self, from: Data(payload.utf8))
    }
}
