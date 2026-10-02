import Foundation

public struct UsageLimit: Codable, Sendable, Equatable, Identifiable {
    public static let sessionSeconds: TimeInterval = 5 * 3_600
    public static let weekSeconds: TimeInterval = 7 * 86_400

    public var id: String
    public var kind: String
    public var title: String
    public var percent: Double
    public var severity: String?
    public var resetsAt: Date?
    public var windowSeconds: TimeInterval
    public var isActive: Bool
    public var modelName: String?
}

public struct SurfaceShare: Codable, Sendable, Equatable {
    public var key: String
    public var displayName: String
    public var percent: Double
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var limits: [UsageLimit]
    public var surfaces: [SurfaceShare]
    public var extraUsageEnabled: Bool
    public var fetchedAt: Date

    public var session: UsageLimit? { limits.first { $0.kind == "session" } }

    public var highestWeekly: UsageLimit? {
        limits.filter { $0.windowSeconds == UsageLimit.weekSeconds }.max { $0.percent < $1.percent }
    }
}

public struct Profile: Codable, Sendable, Equatable {
    public var accountUuid: String
    public var email: String
    public var displayName: String?
    public var fullName: String?
    public var organizationUuid: String
    public var organizationName: String?
    public var organizationType: String?
    public var rateLimitTier: String?
    public var subscriptionStatus: String?
    public var hasClaudeMax: Bool
    public var hasClaudePro: Bool

    public var accountID: String { "\(accountUuid):\(organizationUuid)" }
}

extension UsageSnapshot {
    /// A window ended between this fetch and `now`. A fresh fetch may report a reset that just passed; that is the
    /// server's current number, so only resets after `fetchedAt` count.
    public func hasResetSinceFetch(now: Date) -> Bool {
        limits.contains { limit in limit.resetsAt.map { $0 > fetchedAt && $0 < now } ?? false }
    }
}
