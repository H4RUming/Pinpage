import Foundation
import GRDB

/// 이벤트 종류. 내보내기 파일(M6)에 그대로 쓰이므로 이름을 바꾸지 않는다.
public enum EventType: String, Codable, CaseIterable, Sendable {
    case appLaunch = "app_launch"
    case appQuit = "app_quit"
    case appPause = "app_pause"
    case appResume = "app_resume"
    case problemGenerated = "problem_generated"
    case problemGenerationFailed = "problem_generation_failed"
    case problemShown = "problem_shown"
    case problemAnswered = "problem_answered"
    case problemSkipped = "problem_skipped"
    case questionAsked = "question_asked"
    case answerReceived = "answer_received"
    case hintRequested = "hint_requested"
    case hintReceived = "hint_received"
    case citationOpened = "citation_opened"
    case llmCall = "llm_call"
    case error
}

/// DB에 저장된 이벤트 한 줄.
public struct EventRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "event"

    /// 1부터 증가하는 순번 (같은 밀리초 안에서도 순서를 보장한다)
    public var seq: Int64?
    /// UTC, 밀리초까지 (예: 2026-10-29T03:12:45.123Z)
    public var timestamp: String
    public var type: String
    public var sessionId: String?
    public var participantId: String?
    public var appVersion: String
    /// 이벤트 내용 (JSON, 키 정렬)
    public var payload: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}

/// 이벤트를 즉시 DB에 기록한다. 기록할 때마다 커밋하므로 앱이 강제 종료돼도 직전 이벤트까지 남는다.
public final class EventLogger: @unchecked Sendable {
    public struct Context: Equatable, Sendable {
        public var sessionId: String?
        public var participantId: String?

        public init(sessionId: String? = nil, participantId: String? = nil) {
            self.sessionId = sessionId
            self.participantId = participantId
        }
    }

    private let database: AppDatabase
    private let appVersion: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var _context = Context()

    public init(database: AppDatabase, appVersion: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.appVersion = appVersion
        self.now = now
    }

    /// 실험 세션(M5)이 시작되면 세션·참가자 ID를 붙인다.
    public var context: Context {
        get { lock.withLock { _context } }
        set { lock.withLock { _context = newValue } }
    }

    /// 기록하고 순번을 돌려준다. 기록에 실패해도 앱 동작을 막지 않도록 오류는 nil로 돌려준다.
    @discardableResult
    public func log<Payload: Encodable>(_ type: EventType, _ payload: Payload) -> Int64? {
        do {
            return try record(type, payload)
        } catch {
            return nil
        }
    }

    @discardableResult
    public func log(_ type: EventType) -> Int64? {
        log(type, EmptyPayload())
    }

    /// 오류를 그대로 던지는 기록 (테스트와, 기록 실패를 알려야 하는 곳에서 쓴다).
    @discardableResult
    public func record<Payload: Encodable>(_ type: EventType, _ payload: Payload) throws -> Int64 {
        let context = self.context
        let event = EventRecord(
            seq: nil,
            timestamp: Self.timestamp(now()),
            type: type.rawValue,
            sessionId: context.sessionId,
            participantId: context.participantId,
            appVersion: appVersion,
            payload: try Self.encode(payload)
        )
        return try database.writer.write { db in
            var inserted = event
            try inserted.insert(db)
            return inserted.seq ?? db.lastInsertedRowID
        }
    }

    public func recent(limit: Int) throws -> [EventRecord] {
        try database.writer.read { db in
            try EventRecord.order(Column("seq").desc).limit(limit).fetchAll(db)
        }
    }

    public func all(sessionId: String? = nil) throws -> [EventRecord] {
        try database.writer.read { db in
            var request = EventRecord.order(Column("seq"))
            if let sessionId { request = request.filter(Column("sessionId") == sessionId) }
            return try request.fetchAll(db)
        }
    }

    static func encode<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

public struct EmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

/// LLM 요청 한 번(재시도 포함 각 시도)을 이벤트로 남긴다.
public struct EventLLMCallRecorder: LLMCallRecorder {
    public let logger: EventLogger

    public init(logger: EventLogger) {
        self.logger = logger
    }

    public func record(_ call: LLMCallRecord) async {
        logger.log(.llmCall, LLMCallPayload(call))
    }
}
