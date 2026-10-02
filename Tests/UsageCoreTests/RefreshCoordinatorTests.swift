import Foundation
import Testing
@testable import UsageCore

/// Answers every usage request with the fixture, holding requests while closed until the test opens it.
final class GatedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var isClosed: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private let log: EventLog

    init(closed: Bool = true, log: EventLog) {
        isClosed = closed
        self.log = log
    }

    var waiting: Int { lock.locked { held.count } }

    func open() {
        let waiting = lock.locked { () -> [CheckedContinuation<Void, Never>] in
            isClosed = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.add("usage")
        await withCheckedContinuation { continuation in
            let passes = lock.locked { () -> Bool in
                guard isClosed else { return true }
                held.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
        return (Data(Fixtures.usageJSON.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var all: [String] { lock.locked { entries } }

    func add(_ entry: String) { lock.locked { entries.append(entry) } }
}

/// Polls until `condition` holds (or fails the test after about 5 s).
func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true", sourceLocation: sourceLocation)
}

struct RefreshCoordinatorTests {
    let clock = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    let a = Account.fake("A")
    let b = Account.fake("B")

    /// accounts.json listing A and B, and a ~/.claude.json naming nobody, so both accounts are app-owned.
    func coordinator(_ dir: TempDir, http: any HTTPClient, creds: FakeCredentials = FakeCredentials(),
                     initial: [String: AccountRefreshState] = [:]) throws -> (RefreshCoordinator, AccountStore) {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        try store.save([a, b])
        try Data(#"{"numStartups": 1}"#.utf8).write(to: dir.file(".claude.json"))
        let poller = Poller(api: UsageAPI(http: http, now: clock), credentials: creds, now: clock, initial: initial)
        return (RefreshCoordinator(poller: poller, store: store, terminal: TerminalAccountFile(url: dir.file(".claude.json")),
                                   cacheURL: dir.file("snapshots.json")), store)
    }

    @Test func overlappingRequestsShareOneRound() async throws {
        let dir = try TempDir()
        let http = GatedHTTPClient(log: EventLog())
        let creds = FakeCredentials()
        let (coordinator, _) = try coordinator(dir, http: http, creds: creds)
        let first = Task { try await coordinator.poll(force: false) }
        try await eventually { http.waiting == 1 }
        let second = Task { try await coordinator.poll(force: false) }
        try await eventually { await coordinator.requestCount == 2 }
        http.open()
        let (one, two) = (try await first.value, try await second.value)
        #expect(one.number == 1 && two.number == 1)
        #expect(creds.calls.map(\.id) == [a.id, b.id])
        #expect(two.result == one.result)
    }

    /// Joining an unforced round would skip the accounts in back-off that "Refresh now" means to retry.
    @Test func forcedRequestDuringAnUnforcedRoundRunsAForcedRoundAfterIt() async throws {
        let dir = try TempDir()
        let http = GatedHTTPClient(log: EventLog())
        let creds = FakeCredentials()
        var backingOff = AccountRefreshState.initial
        backingOff.status = .rateLimited
        backingOff.backoffUntil = clock.now().addingTimeInterval(600)
        let (coordinator, _) = try coordinator(dir, http: http, creds: creds, initial: [b.id: backingOff])

        let timer = Task { try await coordinator.poll(force: false) }
        try await eventually { http.waiting == 1 }
        let button = Task { try await coordinator.poll(force: true) }
        try await eventually { await coordinator.requestCount == 2 }
        let again = Task { try await coordinator.poll(force: true) }
        try await eventually { await coordinator.requestCount == 3 }
        http.open()

        let (first, forced, joined) = (try await timer.value, try await button.value, try await again.value)
        #expect(first.number == 1)
        #expect(first.result.states[b.id]?.status == .rateLimited)
        #expect(forced.number == 2)
        #expect(forced.result.states[b.id]?.status == .ok)
        #expect(joined.number == 2)
        #expect(creds.calls.map(\.id) == [a.id, a.id, b.id])
    }

    @Test func exclusiveWorkWaitsForTheRoundAndHoldsOffTheNext() async throws {
        let dir = try TempDir()
        let log = EventLog()
        let http = GatedHTTPClient(log: log)
        let (coordinator, _) = try coordinator(dir, http: http)

        let round = Task { try await coordinator.poll(force: false) }
        try await eventually { http.waiting == 1 }
        let work = Task {
            try await coordinator.exclusive { () -> Bool in
                log.add("exclusive")
                return Thread.isMainThread
            }
        }
        try await eventually { await coordinator.queued == 1 }
        let next = Task { try await coordinator.poll(force: true) }
        try await eventually { await coordinator.queued == 2 }
        #expect(log.all == ["usage"])
        http.open()

        _ = try await round.value
        #expect(try await work.value == false)
        _ = try await next.value
        #expect(log.all == ["usage", "usage", "exclusive", "usage", "usage"])
    }

    @Test func exclusiveErrorReachesTheCallerAndFreesTheNextRound() async throws {
        let dir = try TempDir()
        let (coordinator, _) = try coordinator(dir, http: GatedHTTPClient(closed: false, log: EventLog()))
        await #expect(throws: SwitchError.terminalChanging) {
            try await coordinator.exclusive { () -> Int in throw SwitchError.terminalChanging }
        }
        #expect(try await coordinator.poll(force: false).result.states[a.id]?.status == .ok)
    }

    @Test func roundSavesTheStatesAndTheAccountStatuses() async throws {
        let dir = try TempDir()
        let ok = FakeHTTPClient.json(200, Fixtures.usageJSON)
        let http = FakeHTTPClient([ok, FakeHTTPClient.json(401, "{}"), FakeHTTPClient.json(401, "{}")])
        let (coordinator, store) = try coordinator(dir, http: http)

        let round = try await coordinator.poll(force: false)
        #expect(round.result.states[a.id]?.status == .ok)
        #expect(round.result.states[b.id]?.status == .needsSignIn)
        #expect(StateCache.load(from: dir.file("snapshots.json")) == round.result.states)
        #expect(try store.account(id: b.id)?.status == .needsSignIn)
        #expect(try store.account(id: a.id)?.status == .ok)
        #expect(round.result.accounts.first { $0.id == b.id }?.status == .needsSignIn)
    }

    @Test func corruptClaudeJSONIsReportedAndTheOthersAreStillPolled() async throws {
        let dir = try TempDir()
        let (coordinator, _) = try coordinator(dir, http: GatedHTTPClient(closed: false, log: EventLog()))
        _ = try await coordinator.poll(force: false)   // learns that nobody is signed in in the terminal
        try Data("{ not json".utf8).write(to: dir.file(".claude.json"))
        let round = try await coordinator.poll(force: false)
        #expect(round.result.terminalError?.contains(".claude.json") == true)
        #expect(round.result.states[a.id]?.status == .ok)
        #expect(round.result.states[a.id]?.isStale == false)
    }

    @Test func unreadableAccountListFailsTheRoundAndTheNextOneRetries() async throws {
        let dir = try TempDir()
        let (coordinator, store) = try coordinator(dir, http: GatedHTTPClient(closed: false, log: EventLog()))
        try Data("garbage".utf8).write(to: dir.file("accounts.json"))
        await #expect(throws: (any Error).self) { try await coordinator.poll(force: false) }
        try store.save([a])
        let round = try await coordinator.poll(force: false)
        #expect(round.result.accounts.map(\.id) == [a.id])
        #expect(round.number == 2)
    }
}
