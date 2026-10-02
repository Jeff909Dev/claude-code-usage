import Foundation

/// One finished poll round. Numbers grow with every round, so a caller can ignore a result older than one it has.
public struct PollRound: Sendable {
    public var number: Int
    public var result: PollResult
}

/// Runs poll rounds one at a time, and keeps work that changes logins (switching the terminal, removing an account)
/// out of them, so a token refresh can never rotate a token while it is being copied or deleted (spec §6). Rounds run
/// in tasks of their own: a caller that goes away never cuts one short.
public actor RefreshCoordinator {
    private let poller: Poller
    private let store: AccountStore
    private let terminal: TerminalAccountFile
    private let cacheURL: URL

    /// Held by one round or one exclusive job at a time; the others wait in order.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The newest round not finished yet (running or waiting its turn).
    private var pending: (number: Int, force: Bool, task: Task<PollRound, any Error>)?
    private var lastNumber = 0
    /// Poll requests received so far, joined or not.
    private(set) var requestCount = 0

    /// Rounds and exclusive jobs waiting for their turn.
    var queued: Int { waiters.count }

    public init(poller: Poller, store: AccountStore, terminal: TerminalAccountFile, cacheURL: URL) {
        self.poller = poller
        self.store = store
        self.terminal = terminal
        self.cacheURL = cacheURL
    }

    /// Joins the newest unfinished round when it serves the request (it is forced, or this request is not). A forced
    /// request never joins an unforced round, which skips accounts in back-off: it gets a forced round after it.
    public func poll(force: Bool) async throws -> PollRound {
        requestCount += 1
        if let pending, pending.force || !force { return try await pending.task.value }
        lastNumber += 1
        let number = lastNumber
        let task = Task { try await self.round(number: number, force: force) }
        pending = (number, force, task)
        return try await task.value
    }

    /// Runs `body` on a thread of its own once no round is in flight, holding off new rounds until it returns. For
    /// blocking work (Keychain, ~/.claude.json lock) that must not overlap a token refresh.
    public func exclusive<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func round(number: Int, force: Bool) async throws -> PollRound {
        await acquire()
        defer {
            release()
            if pending?.number == number { pending = nil }
        }
        var result = try await poller.poll(store: store, terminal: terminal, force: force)
        // The cache only speeds up the next launch's first paint.
        try? StateCache.save(result.states, to: cacheURL)
        // The stored status is what the switcher checks, and what a skipped account starts from.
        for account in result.accounts {
            guard let status = result.states[account.id]?.status, status != account.status else { continue }
            try? store.update(id: account.id) { $0.status = status }
        }
        if let accounts = try? store.load() { result.accounts = accounts }
        return PollRound(number: number, result: result)
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
