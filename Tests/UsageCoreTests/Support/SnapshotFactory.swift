import Foundation
@testable import UsageCore

extension UsageSnapshot {
    static func fake(session: Double = 25, weekly: Double = 54, fable: Double? = 64,
                     sessionResets: Date? = Date(timeIntervalSince1970: 1_790_893_800),
                     weeklyResets: Date? = Date(timeIntervalSince1970: 1_791_259_200),
                     fetchedAt: Date = Date(timeIntervalSince1970: 1_790_870_400)) -> UsageSnapshot {
        var limits = [
            UsageLimit(id: "session", kind: "session", title: "Session · 5h", percent: session, severity: nil,
                       resetsAt: sessionResets, windowSeconds: UsageLimit.sessionSeconds, isActive: false, modelName: nil),
            UsageLimit(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: weekly,
                       severity: nil, resetsAt: weeklyResets, windowSeconds: UsageLimit.weekSeconds,
                       isActive: false, modelName: nil),
        ]
        if let fable {
            limits.append(UsageLimit(id: "weekly_scoped:Fable", kind: "weekly_scoped", title: "Week · Fable",
                                     percent: fable, severity: nil, resetsAt: weeklyResets,
                                     windowSeconds: UsageLimit.weekSeconds, isActive: true, modelName: "Fable"))
        }
        return UsageSnapshot(limits: limits, surfaces: [], extraUsageEnabled: false, fetchedAt: fetchedAt)
    }
}
