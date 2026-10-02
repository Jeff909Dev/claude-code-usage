import Foundation
import Testing
@testable import UsageCore

struct PaceTests {
    let reset = Date(timeIntervalSince1970: 1_791_259_200)
    var start: Date { reset.addingTimeInterval(-UsageLimit.weekSeconds) }

    func weekly(_ percent: Double, resetsAt: Date?) -> UsageLimit {
        UsageLimit(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: percent, severity: nil,
                   resetsAt: resetsAt, windowSeconds: UsageLimit.weekSeconds, isActive: false, modelName: nil)
    }

    @Test func levels() {
        #expect(UsageLevel.of(percent: 69.9) == .normal)
        #expect(UsageLevel.of(percent: 70) == .warn)
        #expect(UsageLevel.of(percent: 89) == .warn)
        #expect(UsageLevel.of(percent: 90) == .critical)
    }

    @Test func aheadOfPaceProjectsHundredPercentBeforeReset() throws {
        let now = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds)
        let pace = PaceCalculator.pace(for: weekly(54, resetsAt: reset), now: now)
        #expect(abs(try #require(pace.elapsedFraction) - 0.38) < 1e-9)
        guard case .ahead(let points, let hit) = pace.status else { Issue.record("expected ahead"); return }
        #expect(points == 16)
        let expected = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds * 100 / 54)
        #expect(abs(try #require(hit).timeIntervalSince(expected)) < 0.001)
    }

    @Test(arguments: [(40.0, PaceStatus.onPace), (10.0, PaceStatus.under(points: 28))])
    func onAndUnderPace(percent: Double, expected: PaceStatus) {
        let now = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds)
        #expect(PaceCalculator.pace(for: weekly(percent, resetsAt: reset), now: now).status == expected)
    }

    @Test func aheadAtWindowStartHasNoProjection() {
        // Being ahead of pace always projects 100 % before the reset, except when no time has elapsed yet.
        #expect(PaceCalculator.pace(for: weekly(10, resetsAt: reset), now: start).status
                == .ahead(points: 10, hitsLimitAt: nil))
    }

    @Test func nilResetIsUnknown() {
        let pace = PaceCalculator.pace(for: weekly(0, resetsAt: nil), now: reset)
        #expect(pace == Pace(elapsedFraction: nil, status: .unknown))
    }
}
