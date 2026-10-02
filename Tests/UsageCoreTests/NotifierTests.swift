import Foundation
import Testing
@testable import UsageCore

struct NotifierTests {
    let now = Date(timeIntervalSince1970: 1_790_870_400)
    let reset = Date(timeIntervalSince1970: 1_791_259_200)
    let notifier = Notifier(thresholds: [80, 95], notifyOnReset: true)

    func snapshot(_ weekly: Double, resets: Date? = nil) -> UsageSnapshot {
        .fake(session: 0, weekly: weekly, fable: nil, sessionResets: nil, weeklyResets: resets ?? reset)
    }

    @Test func crossing80FiresOncePerWindow() {
        var state = NotifierState()
        let first = notifier.evaluate(accountID: "A", label: "Work", snapshot: snapshot(81), state: &state, now: now)
        #expect(first.map(\.kind) == [.threshold(80)])
        #expect(first.first?.title == "Work · Week · all models at 81%")
        #expect(notifier.evaluate(accountID: "A", label: "Work", snapshot: snapshot(85), state: &state, now: now).isEmpty)
    }

    @Test func jumpFiresOnlyHighestThreshold() {
        var state = NotifierState()
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
            .map(\.kind) == [.threshold(95)])
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(97), state: &state, now: now).isEmpty)
    }

    @Test func jitteredResetDoesNotRefire() {
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(81), state: &state, now: now)
        let jittered = snapshot(82, resets: reset.addingTimeInterval(0.2))
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: jittered, state: &state, now: now).isEmpty)
    }

    @Test func newWindowCanFireAgainAndResetIsAnnounced() {
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
        let nextWeek = reset.addingTimeInterval(UsageLimit.weekSeconds)
        let afterReset = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(3, resets: nextWeek),
                                           state: &state, now: reset.addingTimeInterval(60))
        #expect(afterReset.map(\.kind) == [.reset])
        #expect(afterReset.first?.title == "U · Week · all models reset")
        let again = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(81, resets: nextWeek),
                                      state: &state, now: reset.addingTimeInterval(3_600))
        #expect(again.map(\.kind) == [.threshold(80)])
    }

    @Test func sessionEndingWithoutANewOneIsAnnouncedAsReset() {
        var state = NotifierState()
        let sessionEnd = now.addingTimeInterval(3_600)
        let busy = UsageSnapshot.fake(session: 96, weekly: 10, fable: nil, sessionResets: sessionEnd, weeklyResets: reset)
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: busy, state: &state, now: now)
            .map(\.kind) == [.threshold(95)])
        let idle = UsageSnapshot.fake(session: 0, weekly: 10, fable: nil, sessionResets: nil, weeklyResets: reset)
        let events = notifier.evaluate(accountID: "A", label: "U", snapshot: idle, state: &state,
                                       now: sessionEnd.addingTimeInterval(60))
        #expect(events.map(\.kind) == [.reset])
        #expect(events.first?.limitID == "session")
        #expect(events.first?.title == "U · Session · 5h reset")
    }

    @Test func disabledOptionsStayQuiet() {
        var state = NotifierState()
        let quiet = Notifier(thresholds: [], notifyOnReset: false)
        #expect(quiet.evaluate(accountID: "A", label: "U", snapshot: snapshot(99), state: &state, now: now).isEmpty)
        #expect(quiet.evaluate(accountID: "A", label: "U", snapshot: snapshot(1, resets: reset.addingTimeInterval(UsageLimit.weekSeconds)),
                               state: &state, now: reset.addingTimeInterval(60)).isEmpty)
    }

    @Test func stateRoundTrips() throws {
        let dir = try TempDir()
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
        try state.save(to: dir.file("notifier.json"))
        #expect(NotifierState.load(from: dir.file("notifier.json")) == state)
    }
}
