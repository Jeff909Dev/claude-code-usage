import Foundation

public enum Format {
    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    public static func money(micros: Int64) -> String {
        let dollars = Double(micros) / 1_000_000
        guard dollars >= 1_000 else { return String(format: "$%.2f", dollars) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: dollars.rounded())) ?? String(Int(dollars)))
    }

    public static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        switch n {
        case ..<1_000: return String(n)
        case ..<10_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "<1m" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    static func formatter(_ pattern: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f
    }

    public static func clock(_ date: Date, calendar: Calendar) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    public static func dayClock(_ date: Date, calendar: Calendar) -> String {
        formatter("EEE HH:mm", calendar: calendar).string(from: date)
    }

    public static func resetText(for limit: UsageLimit, now: Date, calendar: Calendar) -> String {
        guard let resetsAt = limit.resetsAt else {
            return limit.kind == "session" ? "no active session" : "not started"
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "resetting…" }
        if remaining < 86_400 { return "resets \(clock(resetsAt, calendar: calendar)) (in \(duration(remaining)))" }
        return "resets \(dayClock(resetsAt, calendar: calendar))"
    }

    public static func paceLine(_ pace: Pace, percent: Double, calendar: Calendar) -> String {
        if percent >= 100 { return "limit reached" }
        switch pace.status {
        case .unknown: return ""
        case .onPace: return "on pace"
        case .under(let points): return "\(points) pts under pace"
        case .ahead(let points, let hit):
            guard let hit else { return "ahead of pace +\(points) pts" }
            return "ahead of pace +\(points) pts · 100% ≈ \(dayClock(hit, calendar: calendar))"
        }
    }

    /// "just now", "1m ago"; nil without a date.
    public static func ago(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? "just now" : "\(duration(seconds)) ago"
    }

    public static func updatedAgo(_ date: Date?, now: Date) -> String {
        ago(date, now: now).map { "updated \($0)" } ?? "not updated yet"
    }
}
