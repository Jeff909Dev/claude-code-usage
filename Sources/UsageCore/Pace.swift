import Foundation

public enum UsageLevel: Sendable, Equatable {
    case normal, warn, critical

    public static func of(percent: Double) -> UsageLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warn }
        return .normal
    }
}

public enum PaceStatus: Sendable, Equatable {
    case unknown
    case onPace
    case ahead(points: Int, hitsLimitAt: Date?)
    case under(points: Int)
}

public struct Pace: Sendable, Equatable {
    /// Fraction of the window already elapsed (0…1); nil when the window has no reset time.
    public var elapsedFraction: Double?
    public var status: PaceStatus

    public init(elapsedFraction: Double?, status: PaceStatus) {
        self.elapsedFraction = elapsedFraction
        self.status = status
    }
}

public enum PaceCalculator {
    public static let tolerance = 5.0

    public static func pace(for limit: UsageLimit, now: Date) -> Pace {
        guard let resetsAt = limit.resetsAt, limit.windowSeconds > 0 else {
            return Pace(elapsedFraction: nil, status: .unknown)
        }
        let start = resetsAt.addingTimeInterval(-limit.windowSeconds)
        let elapsed = min(max(now.timeIntervalSince(start), 0), limit.windowSeconds)
        let fraction = elapsed / limit.windowSeconds
        let delta = limit.percent - fraction * 100
        if abs(delta) <= tolerance { return Pace(elapsedFraction: fraction, status: .onPace) }
        if delta < 0 { return Pace(elapsedFraction: fraction, status: .under(points: Int((-delta).rounded()))) }

        var hit: Date?
        if limit.percent > 0, elapsed > 0 {
            let projected = start.addingTimeInterval(elapsed * 100 / limit.percent)
            if projected < resetsAt { hit = projected }
        }
        return Pace(elapsedFraction: fraction, status: .ahead(points: Int(delta.rounded()), hitsLimitAt: hit))
    }
}
