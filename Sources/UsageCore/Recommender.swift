import Foundation

public struct RecommendationCandidate: Sendable, Equatable {
    public var accountID: String
    public var isAvailable: Bool
    public var isTerminal: Bool
    public var snapshot: UsageSnapshot?

    public init(accountID: String, isAvailable: Bool, isTerminal: Bool, snapshot: UsageSnapshot?) {
        self.accountID = accountID
        self.isAvailable = isAvailable
        self.isTerminal = isTerminal
        self.snapshot = snapshot
    }
}

public enum Recommender {
    /// Headroom of the tightest relevant limit: session, week (all models), and the week limit of the model the
    /// terminal uses most.
    public static func headroom(_ snapshot: UsageSnapshot, preferredModel: String?) -> Double {
        let relevant = snapshot.limits.filter { limit in
            switch limit.kind {
            case "session", "weekly_all": return true
            case "weekly_scoped":
                guard let preferredModel, let model = limit.modelName else { return false }
                return model.caseInsensitiveCompare(preferredModel) == .orderedSame
            default: return false
            }
        }
        return relevant.map { 100 - $0.percent }.min() ?? 100
    }

    /// The account to suggest, or nil when the terminal account is already (one of) the best.
    public static func best(_ candidates: [RecommendationCandidate], preferredModel: String?) -> String? {
        let scored = candidates.compactMap { c -> (RecommendationCandidate, Double)? in
            guard c.isAvailable, let snapshot = c.snapshot else { return nil }
            return (c, headroom(snapshot, preferredModel: preferredModel))
        }
        guard let top = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == top }.map(\.0)
        if winners.contains(where: \.isTerminal) { return nil }
        return winners.first?.accountID
    }
}

extension RecommendationCandidate {
    /// Only an account whose last refresh succeeded and whose numbers are still current competes (spec §8).
    public init(accountID: String, state: AccountRefreshState?, isTerminal: Bool, now: Date) {
        self.init(accountID: accountID, isAvailable: state.map { $0.status == .ok && !$0.isOutdated(at: now) } ?? false,
                  isTerminal: isTerminal, snapshot: state?.snapshot)
    }
}

extension Recommender {
    /// The account to suggest from the app's state; nil when the terminal account is already (one of) the best.
    public static func best(accounts: [Account], states: [String: AccountRefreshState], terminalID: String?,
                            preferredModel: String?, now: Date) -> String? {
        best(accounts.map { RecommendationCandidate(accountID: $0.id, state: states[$0.id],
                                                    isTerminal: $0.id == terminalID, now: now) },
             preferredModel: preferredModel)
    }
}
