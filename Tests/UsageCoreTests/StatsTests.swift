
import Foundation
import Testing
@testable import UsageCore

struct StatsTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_886_600)   // 2026-10-01 20:30 UTC

    let dir: TempDir
    let index: TranscriptIndex

    init() async throws {
        dir = try TempDir()
        let projects = dir.url.appendingPathComponent("projects", isDirectory: true)
        try TranscriptFixture.write([
            TranscriptFixture.assistant(id: "today-fable"),   // 15:27 UTC, 892 373 µ$, acme/app, s1
            TranscriptFixture.assistant(id: "today-opus", model: "claude-opus-5-5", timestamp: "2026-10-01T18:05:00Z",
                                        cwd: "/Users/dev/code/side-project", session: "s2",
                                        input: 1_000, output: 2_000, cacheRead: 0, cw5m: 0, cw1h: 0),  // 44 000 µ$
            TranscriptFixture.assistant(id: "3d-haiku", model: "claude-haiku-4-5-20251001",
                                        timestamp: "2026-09-28T10:00:00Z", session: "s3",
                                        input: 1_000_000, output: 0, cacheRead: 0, cw5m: 0, cw1h: 0), // 1 000 000 µ$
            TranscriptFixture.assistant(id: "20d-sonnet", model: "claude-sonnet-5", timestamp: "2026-09-11T10:00:00Z",
                                        session: "s4", input: 0, output: 100_000, cacheRead: 0, cw5m: 0, cw1h: 0), // 1 000 000 µ$
            TranscriptFixture.assistant(id: "40d-fable", timestamp: "2026-08-22T10:00:00Z", session: "s5",
                                        input: 0, output: 1_000, cacheRead: 0, cw5m: 0, cw1h: 0),       // excluded
        ], to: projects.appendingPathComponent("p/s.jsonl"))
        index = try TranscriptIndex(databaseURL: dir.file("i.sqlite"), projectsDir: projects, pricing: .builtin)
        try await index.refresh()
    }

    @Test func windowsAndToday() async throws {
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.todayMicros == 936_373)
        #expect(s.last7dMicros == 1_936_373)
        #expect(s.last30dMicros == 2_936_373)
        #expect(s.todayMessages == 2)
        #expect(s.todaySessions == 2)
        #expect(s.todayTokens == 67_463)
        #expect(abs(s.cacheHitRate - 25_373.0 / 61_988.0) < 1e-9)
    }

    @Test func hourlyIsLast24HoursZeroFilled() async throws {
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.hourly.count == 24)
        #expect(s.hourly.last?.hourStart == Date(timeIntervalSince1970: 1_790_884_800))   // 20:00
        #expect(s.hourly.first?.hourStart == Date(timeIntervalSince1970: 1_790_884_800 - 23 * 3_600))
        #expect(s.hourly.first { $0.hourStart == Date(timeIntervalSince1970: 1_790_866_800) }?.costMicros == 892_373)
        #expect(s.hourly.first { $0.hourStart == Date(timeIntervalSince1970: 1_790_877_600) }?.costMicros == 44_000)
        #expect(s.hourly.map(\.costMicros).reduce(0, +) == 936_373)
    }

    @Test func modelMixAndTopProjects() async throws {
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.modelMix.map(\.family) == ["Fable", "Opus"])
        #expect(abs(s.modelMix[0].fraction - 892_373.0 / 936_373.0) < 1e-9)
        #expect(s.topProjects == [ProjectCost(project: "acme/app", costMicros: 892_373),
                                  ProjectCost(project: "code/side-project", costMicros: 44_000)])
    }

    @Test func topModelFamilySince() async throws {
        // Last 7 days: Haiku 1 000 000 µ$ beats Fable 892 373 µ$; today alone: Fable.
        #expect(try await index.topModelFamily(since: now.addingTimeInterval(-7 * 86_400)) == "Haiku")
        #expect(try await index.topModelFamily(since: Date(timeIntervalSince1970: 1_790_812_800)) == "Fable")
        #expect(try await index.topModelFamily(since: now.addingTimeInterval(3_600)) == nil)
    }

    @Test func emptyIndexGivesEmptyStats() async throws {
        let empty = try TranscriptIndex(databaseURL: dir.file("empty.sqlite"), projectsDir: dir.url, pricing: .builtin)
        let s = try await empty.stats(now: now, calendar: utc)
        #expect(s.todayMicros == 0)
        #expect(s.cacheHitRate == 0)
        #expect(s.hourly.count == 24)
        #expect(s.modelMix.isEmpty)
    }
}
