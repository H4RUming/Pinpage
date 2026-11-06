import Foundation

/// 세션 경과 시간을 단계별로 쌓는다.
///
/// 시스템 가동 시간(`ProcessInfo.systemUptime`, Mac이 잠든 동안 멈춤)의 차이로 더하므로
/// 시계를 바꾸거나 Mac이 잠들어도 영향받지 않는다. 앱이 꺼져 있는 동안은 tick이 없으므로 더해지지 않는다.
/// 밀리초 단위로 내림한 가동 시간의 차이를 더하므로 tick을 아무리 많이 해도 반올림 오차가 쌓이지 않는다.
public struct SessionTimer: Equatable, Sendable {
    public private(set) var times: StageTimes
    private var lastUptimeMs: Int?

    public init(times: StageTimes = StageTimes()) {
        self.times = times
    }

    public var isRunning: Bool { lastUptimeMs != nil }

    /// 지금부터 시간을 센다 (세션 시작, 앱 다시 열기, Mac 깨어남).
    public mutating func start(at uptime: TimeInterval) {
        lastUptimeMs = Self.milliseconds(uptime)
    }

    /// 지난 tick부터 지금까지를 `stage`에 더하고, 더한 시간(밀리초)을 돌려준다.
    /// `foreground`가 false면 앱이 맨 앞에 있지 않았던 시간에도 더한다.
    @discardableResult
    public mutating func tick(at uptime: TimeInterval, stage: SessionStage, foreground: Bool) -> Int {
        guard let last = lastUptimeMs else { return 0 }
        let now = Self.milliseconds(uptime)
        lastUptimeMs = now
        let elapsed = now - last
        guard elapsed > 0 else { return 0 }
        times[stage] += elapsed
        if !foreground { times.backgroundMs += elapsed }
        return elapsed
    }

    /// 마지막으로 더하고 멈춘다 (Mac 잠들기, 세션 끝).
    public mutating func stop(at uptime: TimeInterval, stage: SessionStage?, foreground: Bool) {
        if let stage { tick(at: uptime, stage: stage, foreground: foreground) }
        lastUptimeMs = nil
    }

    private static func milliseconds(_ uptime: TimeInterval) -> Int {
        Int((uptime * 1000).rounded(.down))
    }
}
