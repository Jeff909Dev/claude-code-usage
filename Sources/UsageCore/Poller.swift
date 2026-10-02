import Foundation

public struct AccountRefreshState: Codable, Sendable, Equatable {
    public var snapshot: UsageSnapshot?
    public var lastSuccess: Date?
    public var status: AccountStatus
    public var consecutiveRateLimits: Int
    public var backoffUntil: Date?
    /// The snapshot is from an earlier refresh (the last one failed or was skipped).
    public var isStale: Bool

    public static let initial = AccountRefreshState(snapshot: nil, lastSuccess: nil, status: .ok,
                                                    consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)

    /// The numbers no longer describe the account: they are stale, or a window has reset since they were fetched.
    public func isOutdated(at now: Date) -> Bool {
        isStale || (snapshot?.hasResetSinceFetch(now: now) ?? false)
    }
}

public enum Backoff {
    /// A Retry-After beyond this is not believed: it would park the account until a forced refresh.
    static let maxRetryAfter: TimeInterval = 3_600

    public static func delay(afterConsecutiveRateLimits n: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(n, 1) - 1)), 900)
    }
}

/// What one poll cycle saw.
public struct PollResult: Sendable, Equatable {
    public var accounts: [Account]
    /// The terminal's account, as last read from ~/.claude.json.
    public var terminalID: String?
    public var states: [String: AccountRefreshState]
    /// Why ~/.claude.json could not be read, or its account could not be listed. Never carries file contents.
    public var terminalError: String?
}

/// Fetches every account's usage independently; one failing account never blocks the others (spec §10).
public actor Poller {
    /// What the last successful read of ~/.claude.json said.
    private enum TerminalReading {
        case never, nobody, account(String)

        var accountID: String? { if case .account(let id) = self { id } else { nil } }
    }

    private let api: UsageAPI
    private let credentials: any CredentialProviding
    private let now: any DateProvider
    private var states: [String: AccountRefreshState]
    private var lastReading = TerminalReading.never
    /// The refresh round in flight. Overlapping calls join it, so no refresh token is used twice at once.
    private var round: Task<Void, Never>?

    public init(api: UsageAPI, credentials: any CredentialProviding, now: any DateProvider,
                initial: [String: AccountRefreshState] = [:]) {
        self.api = api
        self.credentials = credentials
        self.now = now
        self.states = initial
    }

    public func currentStates() -> [String: AccountRefreshState] { states }

    public static func shouldRefreshOnOpen(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > 60
    }

    /// One cycle: list the terminal's account, then refresh every listed account. Throws only when the account list
    /// cannot be read. An unreadable ~/.claude.json is reported and never stops the others, but an account Claude
    /// Code may own is left alone: refreshed as app-owned, its token could rotate under Claude Code (spec §6).
    public func poll(store: AccountStore, terminal: TerminalAccountFile, force: Bool = false) async throws -> PollResult {
        var terminalError: String?
        let reading: TerminalReading?
        do {
            reading = try terminal.currentIdentity().map { .account($0.accountID) } ?? .nobody
        } catch {
            reading = nil
            terminalError = "Couldn't read \(terminal.url.lastPathComponent): \(error.localizedDescription)"
        }
        if let reading { lastReading = reading }
        if case .account? = reading {
            do { try TerminalAccountImporter.importIfNeeded(store: store, terminal: terminal, now: now.now()) }
            catch { terminalError = "Couldn't list the terminal's account: \(error.localizedDescription)" }
        }

        let accounts = try store.load()
        // Unreadable now: the account last read as Claude Code's stays Claude Code's; before any read, any could be.
        var skipped: [Account] = []
        if reading == nil {
            switch lastReading {
            case .never: skipped = accounts
            case .nobody: break
            case .account(let id): skipped = accounts.filter { $0.id == id }
            }
        }
        let skippedIDs = Set(skipped.map(\.id))
        var result = await refresh(accounts: accounts.filter { !skippedIDs.contains($0.id) },
                                   terminalID: lastReading.accountID, force: force)
        for account in skipped {
            var state = previousState(of: account)
            state.isStale = state.snapshot != nil
            states[account.id] = state
            result[account.id] = state
        }
        return PollResult(accounts: accounts, terminalID: lastReading.accountID, states: result,
                          terminalError: terminalError)
    }

    /// Refreshes the accounts and returns their states. A call made while a round is in flight joins that round and
    /// gets the states it left. Cancelling the caller that started a round stops it before the next account;
    /// accounts it did not finish keep their previous states.
    public func refresh(accounts: [Account], terminalID: String?, force: Bool = false) async -> [String: AccountRefreshState] {
        if let round {
            await round.value
        } else {
            let round = Task { await self.refreshEach(accounts, terminalID: terminalID, force: force) }
            self.round = round
            await withTaskCancellationHandler { await round.value } onCancel: { round.cancel() }
            self.round = nil
        }
        let ids = Set(accounts.map(\.id))
        return states.filter { ids.contains($0.key) }
    }

    private func refreshEach(_ accounts: [Account], terminalID: String?, force: Bool) async {
        for account in accounts {
            guard !Task.isCancelled else { break }
            if let next = await refreshOne(account, isTerminal: account.id == terminalID, force: force) {
                states[account.id] = next
            }
        }
    }

    /// The account's last known state; without one, its stored status (never a made-up ok).
    private func previousState(of account: Account) -> AccountRefreshState {
        if let state = states[account.id] { return state }
        var state = AccountRefreshState.initial
        state.status = account.status
        return state
    }

    /// nil when the refresh was cancelled: nothing was learned, so the account keeps its previous state.
    private func refreshOne(_ account: Account, isTerminal: Bool, force: Bool) async -> AccountRefreshState? {
        var state = previousState(of: account)
        let current = now.now()
        if !force, let until = state.backoffUntil, until > current { return state }
        do {
            let token = try await accessToken(for: account, isTerminal: isTerminal, force: false)
            let snapshot: UsageSnapshot
            do {
                snapshot = try await api.usage(accessToken: token)
            } catch UsageAPIError.unauthorized {
                let fresh = try await accessToken(for: account, isTerminal: isTerminal, force: true)
                // The rejected token came back: Claude Code has not refreshed it yet, or refreshing is off. Retrying
                // with it would only fail again.
                guard fresh != token else {
                    throw isTerminal ? RefreshError.awaitingClaudeCode : RefreshError.refreshDisabled
                }
                snapshot = try await api.usage(accessToken: fresh)
            }
            return AccountRefreshState(snapshot: snapshot, lastSuccess: current, status: .ok,
                                       consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)
        } catch let error where Self.isCancellation(error) {
            return nil
        } catch UsageAPIError.unauthorized, RefreshError.invalidGrant, RefreshError.missingCredentials {
            state.status = .needsSignIn
        } catch RefreshError.awaitingClaudeCode {
            state.status = .waitingForClaudeCode
        } catch UsageAPIError.rateLimited(let retryAfter) {
            state.consecutiveRateLimits += 1
            let hinted = retryAfter.flatMap { $0.isFinite ? min($0, Backoff.maxRetryAfter) : nil } ?? 0
            let wait = max(hinted, Backoff.delay(afterConsecutiveRateLimits: state.consecutiveRateLimits))
            state.backoffUntil = current.addingTimeInterval(wait)
            state.status = .rateLimited
        } catch {
            // Network and server trouble, and refreshing turned off (read-only): keep the last numbers.
            state.status = .offline
        }
        state.isStale = state.snapshot != nil
        return state
    }

    /// Runs in a task of its own: cancelling a poll must not abort a token refresh after the server rotated the
    /// token and before the new one is saved.
    private func accessToken(for account: Account, isTerminal: Bool, force: Bool) async throws -> String {
        let credentials = self.credentials
        return try await Task {
            try await credentials.accessToken(for: account, isTerminal: isTerminal, forceRefresh: force)
        }.value
    }

    /// The caller went away, or URLSession reports a cancelled request: nothing was learned about the account.
    private static func isCancellation(_ error: any Error) -> Bool {
        let cancelled = String(URLError.Code.cancelled.rawValue)
        return Task.isCancelled || error is CancellationError
            || (error as? UsageAPIError) == .network(cancelled) || (error as? RefreshError) == .network(cancelled)
    }
}
