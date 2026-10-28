import Foundation

public enum LLMOperation: String, Sendable {
    case listModels = "list_models"
    case chat
    case embeddings
}

/// LLM 요청 한 번(재시도 포함 각 시도)의 기록.
/// 마일스톤 4에서 이벤트 로그 DB에 그대로 저장한다.
public struct LLMCallRecord: Equatable, Sendable {
    public enum Outcome: String, Sendable {
        case success
        /// 실패했지만 다시 보낸다.
        case retry
        /// 최종 실패.
        case failure
    }

    public let operation: LLMOperation
    public let baseURL: String
    public let model: String?
    /// 1부터 시작하는 시도 번호.
    public let attempt: Int
    public let outcome: Outcome
    /// 요청을 보낸 뒤 응답(또는 실패)까지 걸린 시간.
    public let latencyMs: Int
    public let statusCode: Int?
    public let errorCode: String?
    public let startedAt: Date
}

public protocol LLMCallRecorder: Sendable {
    func record(_ call: LLMCallRecord) async
}

/// 메모리에만 기록한다. 마일스톤 4에서 DB 기록으로 교체한다.
public actor InMemoryLLMCallRecorder: LLMCallRecorder {
    public private(set) var records: [LLMCallRecord] = []

    public init() {}

    public func record(_ call: LLMCallRecord) {
        records.append(call)
    }
}
