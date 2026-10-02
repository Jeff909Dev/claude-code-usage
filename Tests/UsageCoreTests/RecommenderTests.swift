import Foundation
import Testing
@testable import UsageCore

struct RecommenderTests {
    @Test func bestAccountFromTheAppStateOnlyConsidersCurrentOkAccounts() {
        let now = Date(timeIntervalSince1970: 1_790_870_400)
        func state(_ status: AccountStatus, session: Double, stale: Bool = false, fetchedAt: Date? = nil,
                   sessionResets: Date? = nil) -> AccountRefreshState {
            AccountRefreshState(snapshot: .fake(session: session, weekly: session, fable: nil,
                                                sessionResets: sessionResets ?? now.addingTimeInterval(3_600),
                                                fetchedAt: fetchedAt ?? now),
                                lastSuccess: fetchedAt ?? now, status: status, consecutiveRateLimits: 0,
                                backoffUntil: nil, isStale: stale)
        }
        let accounts = ["A", "B", "C", "D"].map { Account.fake($0) }
        let (a, b, c, d) = (accounts[0].id, accounts[1].id, accounts[2].id, accounts[3].id)
        func best(_ states: [String: AccountRefreshState], terminal: String = a) -> String? {
            Recommender.best(accounts: accounts, states: states, terminalID: terminal, preferredModel: nil, now: now)
        }
        let terminal = state(.ok, session: 90)

        #expect(best([a: terminal, b: state(.offline, session: 0, stale: true), c: state(.ok, session: 50)]) == c)
        #expect(best([a: terminal, c: state(.ok, session: 50)], terminal: c) == nil)
        #expect(best([a: terminal, d: state(.ok, session: 0)]) == d)
        // Excluded: stale, rate-limited, waiting for Claude Code, a window reset since the fetch, and no state at all.
        #expect(best([a: terminal, c: state(.ok, session: 0, stale: true)]) == nil)
        #expect(best([a: terminal, c: state(.rateLimited, session: 0)]) == nil)
        #expect(best([a: terminal, c: state(.waitingForClaudeCode, session: 0)]) == nil)
        #expect(best([a: terminal, c: state(.ok, session: 0, fetchedAt: now.addingTimeInterval(-7_200),
                                            sessionResets: now.addingTimeInterval(-60))]) == nil)
        #expect(best([a: terminal]) == nil)
    }

    @Test func headroomUsesTightestRelevantLimit() {
        let s = UsageSnapshot.fake(session: 10, weekly: 54, fable: 64)
        #expect(Recommender.headroom(s, preferredModel: "Fable") == 36)
        #expect(Recommender.headroom(s, preferredModel: "Opus") == 46)
        #expect(Recommender.headroom(s, preferredModel: nil) == 46)
    }

    @Test func picksMostHeadroomAmongAvailableAccounts() {
        let candidates = [
            RecommendationCandidate(accountID: "work", isAvailable: true, isTerminal: true,
                                    snapshot: .fake(session: 25, weekly: 54, fable: 64)),
            RecommendationCandidate(accountID: "personal", isAvailable: true, isTerminal: false,
                                    snapshot: .fake(session: 0, weekly: 12, fable: 20)),
            RecommendationCandidate(accountID: "studio", isAvailable: true, isTerminal: false,
                                    snapshot: .fake(session: 88, weekly: 91, fable: 97)),
            RecommendationCandidate(accountID: "lab", isAvailable: false, isTerminal: false,
                                    snapshot: .fake(session: 0, weekly: 0, fable: 0)),
            RecommendationCandidate(accountID: "new", isAvailable: true, isTerminal: false, snapshot: nil),
        ]
        #expect(Recommender.best(candidates, preferredModel: "Fable") == "personal")
    }

    @Test func returnsNilWhenTerminalIsAlreadyBestOrTied() {
        let candidates = [
            RecommendationCandidate(accountID: "a", isAvailable: true, isTerminal: true, snapshot: .fake(weekly: 10, fable: 10)),
            RecommendationCandidate(accountID: "b", isAvailable: true, isTerminal: false, snapshot: .fake(weekly: 10, fable: 10)),
        ]
        #expect(Recommender.best(candidates, preferredModel: "Fable") == nil)
    }
}
