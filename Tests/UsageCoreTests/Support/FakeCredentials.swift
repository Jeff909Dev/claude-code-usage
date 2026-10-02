import Foundation
@testable import UsageCore

final class FakeCredentials: CredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(id: String, isTerminal: Bool, force: Bool, cancelled: Bool)] = []
    /// Thrown by every call for that account.
    var errors: [String: any Error] = [:]
    /// Thrown only when a refresh is forced (after a 401).
    var forcedErrors: [String: any Error] = [:]
    /// Accounts whose forced refresh hands back the token they already had.
    var unchangedWhenForced: Set<String> = []

    /// `cancelled`: the call ran in a cancelled task.
    var calls: [(id: String, isTerminal: Bool, force: Bool, cancelled: Bool)] { lock.locked { log } }

    func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String {
        try lock.locked {
            log.append((account.id, isTerminal, forceRefresh, Task.isCancelled))
            if let error = errors[account.id] ?? (forceRefresh ? forcedErrors[account.id] : nil) { throw error }
            return forceRefresh && !unchangedWhenForced.contains(account.id) ? "fresh-\(account.id)" : "tok-\(account.id)"
        }
    }
}
