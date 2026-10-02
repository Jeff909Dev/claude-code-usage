import Foundation

public struct NotificationEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case threshold(Int)
        case reset
    }

    public var id: String
    public var accountID: String
    public var limitID: String
    public var kind: Kind
    public var title: String
    public var body: String
}

public struct NotifierState: Codable, Sendable, Equatable {
    /// "<account>|<limit>|<reset minute>" → thresholds already announced in that window.
    public var fired: [String: [Int]] = [:]
    /// "<account>|<limit>" → reset minute of a window that reached ≥ 95 %.
    public var highWindows: [String: Int64] = [:]

    public init() {}

    public static func load(from url: URL) -> NotifierState {
        JSONFile.load(NotifierState.self, from: url) ?? NotifierState()
    }

    public func save(to url: URL) throws {
        try JSONFile.save(self, to: url)
    }
}

public struct Notifier: Sendable {
    public var thresholds: [Int]
    public var notifyOnReset: Bool

    public init(thresholds: [Int], notifyOnReset: Bool) {
        self.thresholds = thresholds
        self.notifyOnReset = notifyOnReset
    }

    /// The API recomputes `resets_at` on each call (microsecond jitter), so windows are keyed by the minute.
    static func minute(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded()) }

    public func evaluate(accountID: String, label: String, snapshot: UsageSnapshot, state: inout NotifierState,
                         now: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let nowMinute = Self.minute(now)
        for limit in snapshot.limits {
            let limitKey = "\(accountID)|\(limit.id)"
            let resetMinute = limit.resetsAt.map(Self.minute)

            if let highMinute = state.highWindows[limitKey], nowMinute >= highMinute, resetMinute != highMinute {
                state.highWindows[limitKey] = nil
                if notifyOnReset {
                    events.append(NotificationEvent(id: "\(limitKey)|reset|\(highMinute)", accountID: accountID,
                                                    limitID: limit.id, kind: .reset,
                                                    title: "\(label) · \(limit.title) reset",
                                                    body: "This limit is available again."))
                }
            }

            guard let resetMinute else { continue }
            let windowKey = "\(limitKey)|\(resetMinute)"
            var fired = Set(state.fired[windowKey] ?? [])
            let crossed = thresholds.sorted().filter { limit.percent >= Double($0) && !fired.contains($0) }
            if let top = crossed.last {
                events.append(NotificationEvent(id: "\(windowKey)|\(top)", accountID: accountID, limitID: limit.id,
                                                kind: .threshold(top),
                                                title: "\(label) · \(limit.title) at \(Format.percent(limit.percent))",
                                                body: "Crossed \(top)% of this limit."))
            }
            fired.formUnion(crossed)   // a jump 50 → 96 announces 95 only, and never 80 later in this window
            if !fired.isEmpty { state.fired[windowKey] = fired.sorted() }
            if limit.percent >= 95 { state.highWindows[limitKey] = resetMinute }
        }
        let weekAgo = nowMinute - 7 * 24 * 60
        state.fired = state.fired.filter { key, _ in (key.split(separator: "|").last.flatMap { Int64($0) } ?? nowMinute) > weekAgo }
        return events
    }
}
