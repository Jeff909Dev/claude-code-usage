import Foundation
import Testing
@testable import UsageCore

struct UsagePresentationTests {
    var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_884_800) // Thu 2026-10-01 20:00 UTC (22:00 Madrid)

    func limit(_ kind: String, percent: Double, resetsAt: Date?) -> UsageLimit {
        UsageLimit(id: kind, kind: kind, title: kind, percent: percent, severity: nil, resetsAt: resetsAt,
                   windowSeconds: kind == "session" ? UsageLimit.sessionSeconds : UsageLimit.weekSeconds,
                   isActive: false, modelName: nil)
    }

    func state(_ status: AccountStatus = .ok, snapshot: UsageSnapshot? = .fake(), stale: Bool = false,
               lastSuccess: Date? = nil) -> AccountRefreshState {
        AccountRefreshState(snapshot: snapshot, lastSuccess: lastSuccess, status: status, consecutiveRateLimits: 0,
                            backoffUntil: nil, isStale: stale)
    }

    // MARK: Limit rows

    @Test func rowUnderPaceShowsResetOnTheTitleLineAndPaceBelow() {
        let row = LimitRowModel.make(limit("session", percent: 25, resetsAt: now.addingTimeInterval(9_000)),
                                     dimmed: false, now: now, calendar: madrid)
        #expect(row.percentText == "25%")
        #expect(row.level == .normal)
        #expect(row.resetText == "resets 00:30 (in 2h 30m)")
        #expect(row.paceFraction == 0.5)
        #expect(row.note == "25 pts under pace")
        #expect(row.noteTone == .muted)
        #expect(!row.isDimmed)
    }

    /// Spec §8: ahead of pace projects when the window hits 100 %, in local time; that warning is coloured.
    @Test func rowAheadOfPaceProjectsTheHit() {
        let weekReset = Date(timeIntervalSince1970: 1_791_259_200) // Tue 2026-10-06 04:00 UTC = 06:00 Madrid
        let row = LimitRowModel.make(limit("weekly_all", percent: 54, resetsAt: weekReset), dimmed: false, now: now,
                                     calendar: madrid)
        #expect(row.resetText == "resets Tue 06:00")
        #expect(row.note == "ahead of pace +16 pts · 100% ≈ Sun 04:31")
        #expect(row.noteTone == .warning)
        #expect(abs(row.paceFraction! - 64.0 / 168) < 1e-9)
    }

    @Test func rowAtTheLimitIsCritical() {
        let row = LimitRowModel.make(limit("session", percent: 100, resetsAt: now.addingTimeInterval(3_600)),
                                     dimmed: false, now: now, calendar: madrid)
        #expect(row.level == .critical)
        #expect(row.note == "limit reached")
        #expect(row.noteTone == .error)
        #expect(LimitRowModel.make(limit("session", percent: 72, resetsAt: now.addingTimeInterval(3_600)),
                                   dimmed: false, now: now, calendar: madrid).level == .warn)
    }

    /// A window without a reset time has not started: no pace marker, and an unused one shows "—", not "0%".
    @Test func rowWithoutResetTimeHasNotStarted() {
        let session = LimitRowModel.make(limit("session", percent: 0, resetsAt: nil), dimmed: false, now: now,
                                         calendar: madrid)
        #expect(session.percentText == "—")
        #expect(session.resetText == nil)
        #expect(session.paceFraction == nil)
        #expect(session.note == "no active session")
        #expect(session.noteTone == .faint)
        let week = LimitRowModel.make(limit("weekly_scoped", percent: 0, resetsAt: nil), dimmed: false, now: now,
                                      calendar: madrid)
        #expect(week.note == "not started")
        #expect(LimitRowModel.make(limit("weekly_all", percent: 3, resetsAt: nil), dimmed: false, now: now,
                                   calendar: madrid).percentText == "3%")
    }

    /// Numbers fetched before the window ended describe the old window: no pace verdict on them.
    @Test func rowWhoseWindowEndedSinceTheFetchWaitsForTheNextRefresh() {
        let row = LimitRowModel.make(limit("session", percent: 80, resetsAt: now.addingTimeInterval(-60)),
                                     dimmed: false, now: now, calendar: madrid)
        #expect(row.resetText == nil)
        #expect(row.paceFraction == nil)
        #expect(row.note == "resetting…")
        #expect(row.noteTone == .faint)
    }

    @Test func dimmedRowShowsLastKnownPercentOnly() {
        let row = LimitRowModel.make(limit("weekly_all", percent: 33, resetsAt: now.addingTimeInterval(86_400)),
                                     dimmed: true, now: now, calendar: madrid)
        #expect(row.isDimmed)
        #expect(row.percentText == "33%")
        #expect(row.resetText == nil)
        #expect(row.paceFraction == nil)
        #expect(row.note == "not refreshed")
        #expect(row.noteTone == .faint)
    }

    // MARK: Limits section

    @Test func currentNumbersHaveNoNote() {
        let fetched = UsageSnapshot.fake(fetchedAt: now.addingTimeInterval(-60))
        let section = LimitsSectionModel.make(state: state(snapshot: fetched), isRefreshing: false, now: now,
                                              calendar: madrid)
        #expect(section.note == nil)
        #expect(section.rows.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(section.placeholder == nil)
        #expect(!section.needsSignIn)
    }

    /// The stored isStale flag means "the last fetch failed"; a window that reset since the fetch also makes the
    /// numbers stale (AccountRefreshState.isOutdated).
    @Test func outdatedNumbersSayStaleAndWhy() {
        func note(_ s: AccountRefreshState) -> String? {
            LimitsSectionModel.make(state: s, isRefreshing: false, now: now, calendar: madrid).note
        }
        let resetSinceFetch = UsageSnapshot.fake(sessionResets: now.addingTimeInterval(-60),
                                                 fetchedAt: now.addingTimeInterval(-3_600))
        #expect(note(state(snapshot: resetSinceFetch)) == "stale")
        #expect(note(state(stale: true)) == "stale")
        #expect(note(state(.offline, stale: true)) == "stale · offline")
        #expect(note(state(.rateLimited, stale: true)) == "stale · rate-limited")
        #expect(note(state(.waitingForClaudeCode, stale: true)) == "stale · waiting for Claude Code")
    }

    @Test func noDataWhileNothingWasFetched() {
        let missing = LimitsSectionModel.make(state: nil, isRefreshing: false, now: now, calendar: madrid)
        #expect(missing.note == "no data")
        #expect(missing.placeholder == .message("no usage data yet"))
        let skipped = LimitsSectionModel.make(state: .initial, isRefreshing: false, now: now, calendar: madrid)
        #expect(skipped.note == "no data")
        let offline = LimitsSectionModel.make(state: state(.offline, snapshot: nil), isRefreshing: false, now: now,
                                              calendar: madrid)
        #expect(offline.note == "offline")
        #expect(offline.placeholder == .message("no usage data yet"))
    }

    @Test func loadingWhileTheFirstRoundRuns() {
        let section = LimitsSectionModel.make(state: nil, isRefreshing: true, now: now, calendar: madrid)
        #expect(section.note == nil)
        #expect(section.placeholder == .loading)
    }

    @Test func emptyLimitsListSaysSo() {
        var empty = UsageSnapshot.fake()
        empty.limits = []
        let section = LimitsSectionModel.make(state: state(snapshot: empty), isRefreshing: true, now: now,
                                              calendar: madrid)
        #expect(section.placeholder == .message("no limits reported"))
    }

    @Test func signedOutAccountShowsLastKnownValuesGreyedOut() {
        let lastSuccess = now.addingTimeInterval(-3 * 86_400)
        let section = LimitsSectionModel.make(state: state(.needsSignIn, stale: true, lastSuccess: lastSuccess),
                                              isRefreshing: false, now: now, calendar: madrid)
        #expect(section.needsSignIn)
        #expect(section.note == "stale")
        #expect(section.signInDetail == "showing last known values · 3d ago")
        #expect(section.rows.count == 3 && section.rows.allSatisfy(\.isDimmed))
        #expect(section.placeholder == nil)

        let never = LimitsSectionModel.make(state: state(.needsSignIn, snapshot: nil), isRefreshing: false, now: now,
                                            calendar: madrid)
        #expect(never.needsSignIn)
        #expect(never.note == nil)
        #expect(never.signInDetail == nil)
        #expect(never.rows.isEmpty && never.placeholder == nil)
    }

    // MARK: Header

    @Test func agoIsShortAndNilWithoutADate() {
        #expect(Format.ago(nil, now: now) == nil)
        #expect(Format.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(Format.ago(now.addingTimeInterval(-75), now: now) == "1m ago")
        #expect(Format.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "3d ago")
    }

    // MARK: Spend stats

    @Test func tileNotes() {
        #expect(StatsText.vsAverage(0.18) == "+18% vs avg")
        #expect(StatsText.vsAverage(-0.052) == "−5% vs avg")
        #expect(StatsText.vsAverage(-0.004) == "+0% vs avg")
        #expect(StatsText.vsAverage(nil) == nil)
        #expect(StatsText.perDay(40_914_285) == "$40.91 / day")
    }

    /// Spec §8: 30-day spend against the summed monthly price of the subscribed plans (pricing.json).
    @Test func planMultipleNamesThePlansPrice() {
        let pricing = PricingTable.builtin
        #expect(StatsText.planMultiple(5.7, plans: ["Max 20x"], pricing: pricing) == "5.7× $200 plan")
        #expect(StatsText.planMultiple(1.94, plans: ["Max 20x", "Pro", "Max 5x", "Enterprise"], pricing: pricing)
                == "1.9× $320 plans")
        #expect(StatsText.planMultiple(nil, plans: ["Max 20x"], pricing: pricing) == nil)
        #expect(StatsText.planMultiple(2, plans: ["Enterprise"], pricing: pricing) == nil)
    }

    @Test func activityLine() {
        var stats = SpendStats.empty
        stats.todayTokens = 18_400_000
        stats.cacheHitRate = 0.917
        stats.todayMessages = 312
        stats.todaySessions = 9
        #expect(StatsText.activity(stats) == ["18.4M tok", "cache hit 92%", "312 msgs", "9 sessions"])
        stats.todayMessages = 1
        stats.todaySessions = 1
        #expect(StatsText.activity(stats).suffix(2) == ["1 msg", "1 session"])
    }

    @Test func hourlyChartLabelsUseLocalTime() {
        let first = Date(timeIntervalSince1970: 1_790_802_000) // 2026-09-30 21:00 UTC = 23:00 Madrid
        let hours = (0..<24).map { HourCost(hourStart: first.addingTimeInterval(Double($0) * 3_600), costMicros: 0) }
        #expect(StatsText.axis(hours, calendar: madrid) == ["23:00", "05:00", "11:00", "17:00", "now"])
        #expect(StatsText.axis([], calendar: madrid) == [])
        let peak = HourCost(hourStart: first.addingTimeInterval(15 * 3_600), costMicros: 6_100_000)
        #expect(StatsText.hourCost(peak, calendar: madrid) == "14:00 · $6.10")
        #expect(StatsText.peak(peak, calendar: madrid) == "peak 14:00 · $6.10")
        #expect(StatsText.peak(nil, calendar: madrid) == nil)
    }

    @Test func indexingProgress() {
        #expect(StatsText.indexing(IndexProgress(filesDone: 1_200, filesTotal: 4_152))
                == "indexing transcripts · 1,200 / 4,152")
    }
}
