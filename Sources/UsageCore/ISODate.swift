import Foundation

public enum ISODate {
    /// Parses ISO 8601 timestamps with any number of fractional digits ("…00.474962+00:00", "…38.176Z").
    public static func parse(_ string: String) -> Date? {
        var base = string
        var fraction = 0.0
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(string[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base)?.addingTimeInterval(fraction)
    }
}
