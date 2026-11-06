import CryptoKit
import Foundation
import GRDB

/// 무엇을 내보낼지.
public enum LogExportScope: Hashable, Sendable {
    /// 참가자 한 명: 그 참가자의 세션과 세션 중 이벤트만
    case participant(String)
    /// 진행자용: 이 Mac의 모든 기록 (세션 밖 이벤트 포함)
    case all

    public var participantId: String? {
        if case .participant(let id) = self { return id }
        return nil
    }

    var name: String {
        switch self {
        case .participant: "participant"
        case .all: "all"
        }
    }
}

/// 내보내는 Mac과 앱 정보 (테스트에서 고정할 수 있게 밖에서 넣는다).
public struct LogExportEnvironment: Sendable {
    public var appInfo: AppInfo
    /// 내보낼 기록에 세션이 없을 때 파일 이름에 쓸 모델 (현재 설정)
    public var fallbackModel: String
    public var exportedAt: Date
    public var timeZone: TimeZone
    public var osVersion: String

    public init(appInfo: AppInfo, fallbackModel: String, exportedAt: Date = Date(), timeZone: TimeZone = .current,
                osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.appInfo = appInfo
        self.fallbackModel = fallbackModel
        self.exportedAt = exportedAt
        self.timeZone = timeZone
        self.osVersion = osVersion
    }
}

/// 내보내기 화면의 참가자 목록 한 줄.
public struct ExportParticipant: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionCount: Int
    public let lastStartedAt: Date
}

/// zip 안 manifest.json. 내보낸 범위, 앱·모델·시각, 파일별 줄 수와 SHA-256.
public struct LogManifest: Codable, Equatable, Sendable {
    public static let formatName = "pinpage-log"
    public static let currentVersion = 1

    public struct FileEntry: Codable, Equatable, Sendable {
        public let name: String
        public let sha256: String
        public let bytes: Int
        /// 데이터 줄 수 (CSV는 헤더 제외)
        public let rows: Int
        /// CSV 열 이름 (JSONL은 null)
        public let columns: [String]?

        private enum CodingKeys: String, CodingKey { case name, sha256, bytes, rows, columns }

        /// 값이 없는 키도 null로 남겨 모든 파일의 키 구성을 같게 한다.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(sha256, forKey: .sha256)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(rows, forKey: .rows)
            try c.encode(columns, forKey: .columns)
        }
    }

    public let format: String
    public let formatVersion: Int
    /// participant 또는 all
    public let scope: String
    /// 참가자 단위로 내보냈을 때의 ID (전체면 nil)
    public let participantId: String?
    /// 들어 있는 세션의 참가자 ID (중복 없이)
    public let participantIds: [String]
    public let appVersion: String
    public let appBuild: String
    /// 세션에서 쓴 모델 (세션이 없으면 내보낼 때의 설정 모델)
    public let models: [String]
    /// UTC
    public let exportedAt: String
    /// 이 Mac의 시간대 기준 (예: 2026-11-06T15:30:12.000+09:00)
    public let exportedAtLocal: String
    public let timeZone: String
    public let osVersion: String
    public let sessionIds: [String]
    public let files: [FileEntry]

    private enum CodingKeys: String, CodingKey {
        case format, formatVersion, scope, participantId, participantIds, appVersion, appBuild, models
        case exportedAt, exportedAtLocal, timeZone, osVersion, sessionIds, files
    }

    /// 값이 없는 키(전체 내보내기의 participantId)도 null로 남겨 모든 파일의 키 구성을 같게 한다.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(scope, forKey: .scope)
        try c.encode(participantId, forKey: .participantId)
        try c.encode(participantIds, forKey: .participantIds)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(appBuild, forKey: .appBuild)
        try c.encode(models, forKey: .models)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(exportedAtLocal, forKey: .exportedAtLocal)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(sessionIds, forKey: .sessionIds)
        try c.encode(files, forKey: .files)
    }
}

/// 내보낼 내용 (zip으로 묶기 전).
public struct LogExport: Sendable {
    public let scope: LogExportScope
    public let suggestedFileName: String
    public let manifest: LogManifest
    /// manifest.json, events.jsonl, sessions.csv, quiz_items.csv 순서
    public let files: [ZipWriter.Entry]
    public let sessionCount: Int
    public let eventCount: Int
    public let quizItemCount: Int
    let exportedAt: Date
    let timeZone: TimeZone

    public func archive() throws -> Data {
        try ZipWriter.archive(files, modified: exportedAt, timeZone: timeZone)
    }
}

/// 로그 내보내기: 원본 이벤트(JSONL), 세션 요약(CSV), 문항별 퀴즈 응답(CSV), manifest를 zip 하나로 묶는다.
///
/// 모든 참가자 파일의 열 구성과 형식이 같아야 진행자가 그대로 이어 붙일 수 있다.
/// 열 목록은 데이터와 관계없이 고정이고, 세션이 하나도 없어도 헤더는 같다.
public struct LogExporter: Sendable {
    public static let manifestFile = "manifest.json"
    public static let eventsFile = "events.jsonl"
    public static let sessionsFile = "sessions.csv"
    public static let quizItemsFile = "quiz_items.csv"

    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 세션 기록이 있는 참가자 (최근에 시작한 순).
    public func participants() throws -> [ExportParticipant] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT participantId, COUNT(*) AS sessionCount, MAX(startedAt) AS lastStartedAt
                FROM experimentSession GROUP BY participantId ORDER BY lastStartedAt DESC, participantId
                """).map { row in
                ExportParticipant(id: row["participantId"], sessionCount: row["sessionCount"], lastStartedAt: row["lastStartedAt"])
            }
        }
    }

    public func export(_ scope: LogExportScope, environment: LogExportEnvironment) throws -> LogExport {
        let data = try database.writer.read { db -> Loaded in
            let sessions: [ExperimentSession]
            let events: [EventRecord]
            switch scope {
            case .participant(let id):
                sessions = try ExperimentSession.filter(Column("participantId") == id).order(Column("startedAt"), Column("id")).fetchAll(db)
                events = try EventRecord.filter(Column("participantId") == id).order(Column("seq")).fetchAll(db)
            case .all:
                sessions = try ExperimentSession.order(Column("startedAt"), Column("id")).fetchAll(db)
                events = try EventRecord.order(Column("seq")).fetchAll(db)
            }
            let attempts = try QuizAttempt.filter(sessions.map(\.id).contains(Column("sessionId"))).order(Column("id")).fetchAll(db)
            let quizSets = try QuizSetRecord.filter(keys: Set(sessions.map(\.quizSetId))).fetchAll(db)
            let sets = try LearningSet.filter(keys: Set(sessions.compactMap(\.setId))).fetchAll(db)
            return Loaded(sessions: sessions, events: events, attempts: attempts,
                          quizSets: Dictionary(uniqueKeysWithValues: quizSets.map { ($0.id, $0) }),
                          setNames: Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.name) }))
        }

        let eventsBySession = Dictionary(grouping: data.events.filter { $0.sessionId != nil }, by: { $0.sessionId! })
        let attemptsBySession = Dictionary(grouping: data.attempts, by: \.sessionId)
        var summaries: [SessionSummary] = []
        var items: [QuizItemRow] = []
        for session in data.sessions {
            let events = eventsBySession[session.id] ?? []
            let attempts = attemptsBySession[session.id] ?? []
            let quizSet = data.quizSets[session.quizSetId]
            summaries.append(SessionSummary(session: session, events: events, attempts: attempts, quizSet: quizSet,
                                            setName: session.setId.flatMap { data.setNames[$0] },
                                            exportedAt: environment.exportedAt))
            items += QuizItemRow.rows(session: session, events: events, attempts: attempts, quizSet: quizSet)
        }

        let eventsData = Self.jsonLines(data.events)
        let sessionsData = CSV.encode(summaries, columns: SessionSummary.columns)
        let itemsData = CSV.encode(items, columns: QuizItemRow.columns)
        let entries = [
            (Self.eventsFile, eventsData, data.events.count, nil as [String]?),
            (Self.sessionsFile, sessionsData, summaries.count, SessionSummary.columns.map(\.name)),
            (Self.quizItemsFile, itemsData, items.count, QuizItemRow.columns.map(\.name)),
        ]

        var models = Self.distinct(summaries.compactMap(\.model).filter { !$0.isEmpty })
        if models.isEmpty, !environment.fallbackModel.isEmpty { models = [environment.fallbackModel] }
        let manifest = LogManifest(
            format: LogManifest.formatName,
            formatVersion: LogManifest.currentVersion,
            scope: scope.name,
            participantId: scope.participantId,
            participantIds: Self.distinct(data.sessions.map(\.participantId)),
            appVersion: environment.appInfo.version,
            appBuild: environment.appInfo.build,
            models: models,
            exportedAt: EventLogger.timestamp(environment.exportedAt),
            exportedAtLocal: Self.localTimestamp(environment.exportedAt, timeZone: environment.timeZone),
            timeZone: environment.timeZone.identifier,
            osVersion: environment.osVersion,
            sessionIds: data.sessions.map(\.id),
            files: entries.map { name, data, rows, columns in
                LogManifest.FileEntry(name: name, sha256: Self.sha256(data), bytes: data.count, rows: rows, columns: columns)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)

        return LogExport(
            scope: scope,
            suggestedFileName: Self.fileName(scope: scope, appVersion: environment.appInfo.version, models: models,
                                             exportedAt: environment.exportedAt),
            manifest: manifest,
            files: [ZipWriter.Entry(name: Self.manifestFile, data: manifestData)]
                + entries.map { ZipWriter.Entry(name: $0.0, data: $0.1) },
            sessionCount: summaries.count,
            eventCount: data.events.count,
            quizItemCount: items.count,
            exportedAt: environment.exportedAt,
            timeZone: environment.timeZone)
    }

    private struct Loaded {
        let sessions: [ExperimentSession]
        let events: [EventRecord]
        let attempts: [QuizAttempt]
        let quizSets: [String: QuizSetRecord]
        let setNames: [String: String]
    }

    // MARK: - events.jsonl

    /// 이벤트 한 줄에 하나. 맨 위 키는 항상 같은 7개, 같은 순서이고 값이 없으면 null.
    /// payload는 DB에 저장한 JSON 객체를 그대로 넣는다 (키 정렬).
    static func jsonLines(_ events: [EventRecord]) -> Data {
        var text = ""
        for event in events {
            text += "{\"seq\":\(event.seq.map(String.init) ?? "null")"
            text += ",\"timestamp\":\(jsonString(event.timestamp))"
            text += ",\"type\":\(jsonString(event.type))"
            text += ",\"sessionId\":\(jsonString(event.sessionId))"
            text += ",\"participantId\":\(jsonString(event.participantId))"
            text += ",\"appVersion\":\(jsonString(event.appVersion))"
            text += ",\"payload\":\(payloadJSON(event.payload))}\n"
        }
        return Data(text.utf8)
    }

    private static func jsonString(_ value: String?) -> String {
        guard let value else { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// 저장된 내용이 JSON 객체이고 한 줄이면 그대로, 아니면(생길 일은 없지만) 문자열로 감싼다.
    private static func payloadJSON(_ payload: String) -> String {
        let isObject = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) is [String: Any]
        if isObject && !payload.contains(where: { $0 == "\n" || $0 == "\r" }) { return payload }
        return "{\"unparsed\":\(jsonString(payload))}"
    }

    // MARK: - 파일 이름

    /// 예: pinpage-log_P01_v0.1.0_qwen3.5-27b_20261106T063012Z.zip (전체면 참가자 자리에 all)
    public static func fileName(scope: LogExportScope, appVersion: String, models: [String], exportedAt: Date) -> String {
        let who = scope.participantId.map { sanitize($0, allowUnderscore: true) } ?? "all"
        let model = sanitize(models.joined(separator: "+"), allowUnderscore: false)
        return "pinpage-log_\(who.isEmpty ? "unknown" : who)_v\(sanitize(appVersion, allowUnderscore: false))_\(model.isEmpty ? "unknown-model" : String(model.prefix(60)))_\(utcStamp(exportedAt)).zip"
    }

    /// 영문, 숫자, 점, 하이픈만 남기고 나머지는 하이픈으로 (연속되면 하나로).
    static func sanitize(_ text: String, allowUnderscore: Bool) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let allowed = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"))
                || (allowUnderscore && scalar == "_")
            if allowed {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result += "-"
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func localTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// 로그를 내보냈을 때 (같은 참가자를 여러 번 내보냈는지 알 수 있게).
public struct LogExportedPayload: Codable, Equatable, Sendable {
    /// participant 또는 all
    public let scope: String
    public let participantId: String?
    public let fileName: String
    /// zip 파일의 SHA-256 (진행자가 받은 파일과 같은지 확인)
    public let sha256: String
    public let bytes: Int
    public let sessionCount: Int
    public let eventCount: Int
    public let quizItemCount: Int

    public init(export: LogExport, fileName: String, archive: Data) {
        scope = export.scope.name
        participantId = export.scope.participantId
        self.fileName = fileName
        sha256 = LogExporter.sha256(archive)
        bytes = archive.count
        sessionCount = export.sessionCount
        eventCount = export.eventCount
        quizItemCount = export.quizItemCount
    }
}
