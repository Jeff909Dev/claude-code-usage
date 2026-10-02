
import Foundation

public struct HourCost: Sendable, Equatable {
    public var hourStart: Date
    public var costMicros: Int64
}

public struct ModelShare: Sendable, Equatable {
    public var family: String
    public var costMicros: Int64
    public var fraction: Double
}

public struct ProjectCost: Sendable, Equatable {
    public var project: String
    public var costMicros: Int64
}

public struct SpendStats: Sendable, Equatable {
    public var todayMicros: Int64
    public var last7dMicros: Int64
    public var last30dMicros: Int64
    public var todayTokens: Int64
    public var cacheHitRate: Double
    public var todayMessages: Int
    public var todaySessions: Int
    public var hourly: [HourCost]
    public var modelMix: [ModelShare]
    public var topProjects: [ProjectCost]

    public static let empty = SpendStats(todayMicros: 0, last7dMicros: 0, last30dMicros: 0, todayTokens: 0,
                                         cacheHitRate: 0, todayMessages: 0, todaySessions: 0, hourly: [],
                                         modelMix: [], topProjects: [])
}

extension TranscriptIndex {
    /// Index buckets are aligned to UTC epoch hours, while today/7d/30d come from the injected calendar. In
    /// half-hour-offset time zones (e.g. India) up to 45 min around local midnight may be misattributed.
    public func stats(now: Date, calendar: Calendar) throws -> SpendStats {
        let today = calendar.startOfDay(for: now)
        let day7 = calendar.date(byAdding: .day, value: -6, to: today)!
        let day30 = calendar.date(byAdding: .day, value: -29, to: today)!
        let t = Int64(today.timeIntervalSince1970)

        func sumCost(since: Date) throws -> Int64 {
            try db.prepare("SELECT COALESCE(SUM(cost_micros), 0) FROM buckets WHERE hour >= ?")
                .rows([.int(Int64(since.timeIntervalSince1970))])[0][0].intValue
        }

        let tokenRow = try db.prepare("""
            SELECT COALESCE(SUM(input), 0), COALESCE(SUM(output), 0), COALESCE(SUM(cache_read), 0),
                   COALESCE(SUM(cw5m), 0), COALESCE(SUM(cw1h), 0), COALESCE(SUM(messages), 0)
            FROM buckets WHERE hour >= ?
            """).rows([.int(t)])[0]
        let input = tokenRow[0].intValue, output = tokenRow[1].intValue, cacheRead = tokenRow[2].intValue
        let writes = tokenRow[3].intValue + tokenRow[4].intValue
        let promptSide = input + cacheRead + writes

        let sessions = try db.prepare("SELECT COUNT(DISTINCT session_id) FROM sessions WHERE hour >= ?")
            .rows([.int(t)])[0][0].intValue

        let currentHour = Int64((now.timeIntervalSince1970 / 3_600).rounded(.down)) * 3_600
        let firstHour = currentHour - 23 * 3_600
        var byHour: [Int64: Int64] = [:]
        for row in try db.prepare("SELECT hour, SUM(cost_micros) FROM buckets WHERE hour >= ? GROUP BY hour")
            .rows([.int(firstHour)]) {
            byHour[row[0].intValue] = row[1].intValue
        }
        let hourly = (0..<24).map { i -> HourCost in
            let hour = firstHour + Int64(i) * 3_600
            return HourCost(hourStart: Date(timeIntervalSince1970: TimeInterval(hour)), costMicros: byHour[hour] ?? 0)
        }

        let byFamily = try costByFamily(sinceEpoch: t)
        let todayCost = byFamily.values.reduce(0, +)
        let mix = byFamily.filter { $0.value > 0 }
            .map { ModelShare(family: $0.key, costMicros: $0.value,
                              fraction: todayCost > 0 ? Double($0.value) / Double(todayCost) : 0) }
            .sorted { ($0.costMicros, $1.family) > ($1.costMicros, $0.family) }

        let projects = try db.prepare("""
            SELECT project, SUM(cost_micros) AS c FROM buckets WHERE hour >= ?
            GROUP BY project HAVING c > 0 ORDER BY c DESC, project ASC LIMIT 3
            """).rows([.int(t)]).map { ProjectCost(project: $0[0].textValue ?? "unknown", costMicros: $0[1].intValue) }

        return SpendStats(todayMicros: try sumCost(since: today), last7dMicros: try sumCost(since: day7),
                          last30dMicros: try sumCost(since: day30), todayTokens: promptSide + output,
                          cacheHitRate: promptSide > 0 ? Double(cacheRead) / Double(promptSide) : 0,
                          todayMessages: Int(tokenRow[5].intValue), todaySessions: Int(sessions),
                          hourly: hourly, modelMix: mix, topProjects: projects)
    }

    /// The model family with the highest cost since `since` ("Fable"), used to pick the relevant weekly limit.
    public func topModelFamily(since: Date) throws -> String? {
        try costByFamily(sinceEpoch: Int64(since.timeIntervalSince1970))
            .filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    /// Cost in µ$ per model family (unrecognised models keep their raw id) for buckets starting at or after `sinceEpoch`.
    private func costByFamily(sinceEpoch: Int64) throws -> [String: Int64] {
        var byFamily: [String: Int64] = [:]
        for row in try db.prepare("SELECT model, SUM(cost_micros) FROM buckets WHERE hour >= ? GROUP BY model")
            .rows([.int(sinceEpoch)]) {
            let model = row[0].textValue ?? "unknown"
            byFamily[ModelNames.family(model) ?? model, default: 0] += row[1].intValue
        }
        return byFamily
    }
}
