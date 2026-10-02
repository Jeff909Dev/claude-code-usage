import Foundation

/// One row of the popover's limits section (spec §8).
public struct LimitRowModel: Sendable, Equatable, Identifiable {
    public enum Tone: Sendable, Equatable { case muted, faint, warning, error }

    public var id: String
    public var title: String
    /// "25%", or "—" for a window that hasn't started and has no usage.
    public var percentText: String
    public var percent: Double
    public var level: UsageLevel
    /// Where the pace marker sits on the bar (elapsed fraction of the window); nil hides it.
    public var paceFraction: Double?
    /// "resets 00:30 (in 2h 30m)" next to the title; nil when there is no reset ahead or the numbers are old.
    public var resetText: String?
    /// The ⎿ line under the bar; empty when there is nothing to say.
    public var note: String
    public var noteTone: Tone
    /// The last known values of an account that must sign in again.
    public var isDimmed: Bool

    public static func make(_ limit: UsageLimit, dimmed: Bool, now: Date, calendar: Calendar) -> LimitRowModel {
        var row = LimitRowModel(
            id: limit.id, title: limit.title,
            percentText: limit.resetsAt == nil && limit.percent == 0 ? "—" : Format.percent(limit.percent),
            percent: limit.percent, level: UsageLevel.of(percent: limit.percent), paceFraction: nil, resetText: nil,
            note: "not refreshed", noteTone: .faint, isDimmed: dimmed)
        if dimmed { return row }
        let reset = Format.resetText(for: limit, now: now, calendar: calendar)
        // No window yet ("no active session"), or one that ended after these numbers were fetched ("resetting…").
        guard let resetsAt = limit.resetsAt, resetsAt > now else {
            row.note = reset
            return row
        }
        let pace = PaceCalculator.pace(for: limit, now: now)
        row.resetText = reset
        row.paceFraction = pace.elapsedFraction
        row.note = Format.paceLine(pace, percent: limit.percent, calendar: calendar)
        if limit.percent >= 100 {
            row.noteTone = .error
        } else if case .ahead = pace.status {
            row.noteTone = .warning
        } else {
            row.noteTone = .muted
        }
        return row
    }
}

/// What the limits section shows for one account.
public struct LimitsSectionModel: Sendable, Equatable {
    public enum Placeholder: Sendable, Equatable {
        case loading
        case message(String)
    }

    /// Next to the "limits" label: why the numbers may not be current ("stale · offline"); nil while they are.
    public var note: String?
    public var needsSignIn: Bool
    /// Under the sign-in notice: "showing last known values · 3d ago".
    public var signInDetail: String?
    public var rows: [LimitRowModel]
    /// Shown instead of rows when there are none to show.
    public var placeholder: Placeholder?

    public static func make(state: AccountRefreshState?, isRefreshing: Bool, now: Date,
                            calendar: Calendar) -> LimitsSectionModel {
        let needsSignIn = state?.status == .needsSignIn
        let snapshot = state?.snapshot
        let rows = (snapshot?.limits ?? []).map { LimitRowModel.make($0, dimmed: needsSignIn, now: now, calendar: calendar) }
        let placeholder: Placeholder? =
            if !rows.isEmpty || needsSignIn { nil }
            else if snapshot != nil { .message("no limits reported") }
            else if isRefreshing { .loading }
            else { .message("no usage data yet") }
        return LimitsSectionModel(
            note: note(state: state, isRefreshing: isRefreshing, now: now), needsSignIn: needsSignIn,
            signInDetail: needsSignIn && snapshot != nil
                ? ["showing last known values", Format.ago(state?.lastSuccess, now: now)].compactMap { $0 }
                    .joined(separator: " · ")
                : nil,
            rows: rows, placeholder: placeholder)
    }

    /// The stored `isStale` flag means the last fetch failed; `isOutdated` also counts a window that reset since.
    static func note(state: AccountRefreshState?, isRefreshing: Bool, now: Date) -> String? {
        guard let state, state.snapshot != nil else {
            // Nothing to call stale: say why there is nothing, unless it is coming or the sign-in notice says so.
            if isRefreshing || state?.status == .needsSignIn { return nil }
            return StatusText.of(state: state)
        }
        let outdated = state.isOutdated(at: now)
        switch state.status {
        case .ok: return outdated ? "stale" : nil
        case .needsSignIn: return "stale"
        default:
            let reason = StatusText.of(state.status)
            return outdated ? "stale · \(reason)" : reason
        }
    }
}

/// Text of the popover's spend section.
public enum StatsText {
    /// "+18% vs avg" (today against the six previous days); nil without history.
    public static func vsAverage(_ change: Double?) -> String? {
        guard let change else { return nil }
        let points = Int((change * 100).rounded())
        return (points < 0 ? "−\(-points)%" : "+\(points)%") + " vs avg"
    }

    public static func perDay(_ micros: Int64) -> String { "\(Format.money(micros: micros)) / day" }

    /// "5.7× $200 plan": spend against the summed monthly price of the subscribed plans that have a known price; nil
    /// when none has.
    public static func planMultiple(_ multiple: Double?, plans: [String], pricing: PricingTable) -> String? {
        let prices = plans.compactMap { pricing.plans[$0] }
        guard let multiple, !prices.isEmpty else { return nil }
        return String(format: "%.1f× $%.0f plan", multiple, prices.reduce(0, +)) + (prices.count == 1 ? "" : "s")
    }

    /// ["18.4M tok", "cache hit 92%", "312 msgs", "9 sessions"]
    public static func activity(_ stats: SpendStats) -> [String] {
        ["\(Format.tokens(stats.todayTokens)) tok",
         "cache hit \(Format.percent(stats.cacheHitRate * 100))",
         count(stats.todayMessages, "msg"),
         count(stats.todaySessions, "session")]
    }

    /// "14:00 · $6.10"
    public static func hourCost(_ hour: HourCost, calendar: Calendar) -> String {
        "\(Format.clock(hour.hourStart, calendar: calendar)) · \(Format.money(micros: hour.costMicros))"
    }

    public static func peak(_ hour: HourCost?, calendar: Calendar) -> String? {
        hour.map { "peak \(hourCost($0, calendar: calendar))" }
    }

    /// Labels under the hourly bars: every sixth hour from the first, then "now" for the last.
    public static func axis(_ hours: [HourCost], calendar: Calendar) -> [String] {
        guard !hours.isEmpty else { return [] }
        return stride(from: 0, to: hours.count - 1, by: 6).map { Format.clock(hours[$0].hourStart, calendar: calendar) }
            + ["now"]
    }

    /// "indexing transcripts · 1,200 / 4,152"
    public static func indexing(_ progress: IndexProgress) -> String {
        "indexing transcripts · \(grouped(progress.filesDone)) / \(grouped(progress.filesTotal))"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
