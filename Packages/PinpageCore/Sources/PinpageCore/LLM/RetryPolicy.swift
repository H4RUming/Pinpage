import Foundation

/// 실패한 요청을 다시 보낼지와 얼마나 기다릴지 정한다.
public struct RetryPolicy: Equatable, Sendable {
    /// 첫 시도를 뺀 최대 재시도 횟수.
    public var maxRetries: Int
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxRetries: Int, baseDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(4)) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public func shouldRetry(_ kind: LLMErrorKind, retriesSoFar: Int) -> Bool {
        kind.isRetryable && retriesSoFar < maxRetries
    }

    /// n번째 재시도 전에 기다릴 시간 (n은 1부터). 0.5초, 1초, 2초, 4초, 4초…
    public func delay(beforeRetry n: Int) -> Duration {
        let exponent = min(max(n - 1, 0), 16)
        return min(baseDelay * (1 << exponent), maxDelay)
    }
}
