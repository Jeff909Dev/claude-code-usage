import Foundation
import Testing
@testable import UsageCore

struct FormatTests {
    var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_884_800) // 2026-10-01 20:00 UTC (22:00 Madrid)

    func limit(kind: String, resetsAt: Date?) -> UsageLimit {
        UsageLimit(id: kind, kind: kind, title: kind, percent: 0, severity: nil, resetsAt: resetsAt,
                   windowSeconds: kind == "session" ? UsageLimit.sessionSeconds : UsageLimit.weekSeconds,
                   isActive: false, modelName: nil)
    }

    @Test func numbers() {
        #expect(Format.percent(25.4) == "25%")
        #expect(Format.money(micros: 48_200_000) == "$48.20")
        #expect(Format.money(micros: 0) == "$0.00")
        #expect(Format.money(micros: 1_140_000_000) == "$1,140")
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1_260) == "1.3K")
        #expect(Format.tokens(950_000) == "950K")
        #expect(Format.tokens(18_400_000) == "18.4M")
        #expect(Format.duration(30) == "<1m")
        #expect(Format.duration(2_700) == "45m")
        #expect(Format.duration(9_000) == "2h 30m")
        #expect(Format.duration(273_600) == "3d 4h")
    }

    @Test func resetTextUsesCalendarTimeZone() {
        let soon = Date(timeIntervalSince1970: 1_790_893_800)   // 22:30 UTC = 00:30 Madrid
        #expect(Format.resetText(for: limit(kind: "session", resetsAt: soon), now: now, calendar: madrid)
                == "resets 00:30 (in 2h 30m)")
        let later = Date(timeIntervalSince1970: 1_791_259_200)  // Tue 04:00 UTC = 06:00 Madrid
        #expect(Format.resetText(for: limit(kind: "weekly_all", resetsAt: later), now: now, calendar: madrid)
                == "resets Tue 06:00")
    }

    @Test func nilResetShowsNoActiveSession() {
        #expect(Format.resetText(for: limit(kind: "session", resetsAt: nil), now: now, calendar: madrid) == "no active session")
        #expect(Format.resetText(for: limit(kind: "weekly_all", resetsAt: nil), now: now, calendar: madrid) == "not started")
    }

    @Test func paceLines() {
        let hit = Date(timeIntervalSince1970: 1_791_028_800)    // Sat 2026-10-03 12:00 UTC = 14:00 Madrid
        #expect(Format.paceLine(Pace(elapsedFraction: 0.3, status: .onPace), percent: 30, calendar: madrid) == "on pace")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.4, status: .under(points: 12)), percent: 28, calendar: madrid)
                == "12 pts under pace")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.38, status: .ahead(points: 16, hitsLimitAt: hit)), percent: 54,
                                calendar: madrid) == "ahead of pace +16 pts · 100% ≈ Sat 14:00")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.9, status: .ahead(points: 7, hitsLimitAt: nil)), percent: 97,
                                calendar: madrid) == "ahead of pace +7 pts")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.5, status: .ahead(points: 50, hitsLimitAt: nil)), percent: 100,
                                calendar: madrid) == "limit reached")
        #expect(Format.paceLine(Pace(elapsedFraction: nil, status: .unknown), percent: 0, calendar: madrid) == "")
    }

    @Test func updatedAgo() {
        #expect(Format.updatedAgo(nil, now: now) == "not updated yet")
        #expect(Format.updatedAgo(now.addingTimeInterval(-20), now: now) == "updated just now")
        #expect(Format.updatedAgo(now.addingTimeInterval(-75), now: now) == "updated 1m ago")
    }
}
