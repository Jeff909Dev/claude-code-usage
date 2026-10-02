import Foundation
import Testing
@testable import UsageCore

struct PollerTests {
    let clock = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    let b = Account.fake("B")
    var ok: FakeHTTPClient.Stub { FakeHTTPClient.json(200, Fixtures.usageJSON) }

    func poller(_ http: FakeHTTPClient, _ creds: FakeCredentials, initial: [String: AccountRefreshState] = [:]) -> Poller {
        Poller(api: UsageAPI(http: http, now: clock), credentials: creds, now: clock, initial: initial)
    }

    var cached: [String: AccountRefreshState] {
        [b.id: AccountRefreshState(snapshot: .fake(), lastSuccess: clock.now().addingTimeInterval(-600), status: .ok,
                                   consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)]
    }

    /// accounts.json listing B, and a .claude.json whose terminal account is A.
    func workspace(_ dir: TempDir) throws -> (AccountStore, TerminalAccountFile) {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        try store.upsert(b)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "a@example.com").utf8).write(to: dir.file(".claude.json"))
        return (store, TerminalAccountFile(url: dir.file(".claude.json")))
    }

    @Test func successStoresSnapshot() async {
        let states = await poller(FakeHTTPClient([ok]), FakeCredentials()).refresh(accounts: [b], terminalID: b.id)
        let s = states[b.id]
        #expect(s?.status == .ok)
        #expect(s?.snapshot?.limits.count == 3)
        #expect(s?.lastSuccess == clock.now())
        #expect(s?.isStale == false)
    }

    @Test func passesTerminalFlagToCredentials() async {
        let creds = FakeCredentials()
        _ = await poller(FakeHTTPClient([ok, ok]), creds).refresh(accounts: [.fake("A"), b], terminalID: b.id)
        #expect(creds.calls.map(\.isTerminal) == [false, true])
    }

    @Test func unauthorizedRetriesOnceWithForcedRefresh() async {
        let creds = FakeCredentials()
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}"), ok])
        let states = await poller(http, creds).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .ok)
        #expect(creds.calls.map(\.force) == [false, true])
        #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-\(b.id)")
    }

    @Test func unauthorizedTwiceMarksNeedsSignInAndKeepsSnapshot() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}"), FakeHTTPClient.json(401, "{}")])
        let states = await poller(http, FakeCredentials(), initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .needsSignIn)
        #expect(states[b.id]?.snapshot == .fake())
        #expect(states[b.id]?.isStale == true)
    }

    /// 403 is not a rejected login: no forced refresh, no "Sign in again", the last numbers stay.
    @Test func forbiddenUsageMarksOfflineWithoutRefreshing() async {
        let creds = FakeCredentials()
        let http = FakeHTTPClient([FakeHTTPClient.json(403, "{}")])
        let states = await poller(http, creds, initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .offline)
        #expect(states[b.id]?.snapshot == .fake())
        #expect(states[b.id]?.isStale == true)
        #expect(creds.calls.map(\.force) == [false])
        #expect(http.requests.count == 1)
    }

    @Test func invalidGrantMarksNeedsSignIn() async {
        let creds = FakeCredentials()
        creds.errors[b.id] = RefreshError.invalidGrant
        let http = FakeHTTPClient([])
        let states = await poller(http, creds).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .needsSignIn)
        #expect(http.requests.isEmpty)
    }

    @Test func awaitingClaudeCodeKeepsLastSnapshotAsStale() async {
        let creds = FakeCredentials()
        creds.forcedErrors[b.id] = RefreshError.awaitingClaudeCode
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}")])
        let states = await poller(http, creds, initial: cached).refresh(accounts: [b], terminalID: b.id)
        #expect(states[b.id]?.status == .waitingForClaudeCode)
        #expect(states[b.id]?.isStale == true)
        #expect(states[b.id]?.snapshot == .fake())
        #expect(states[b.id]?.lastSuccess == cached[b.id]?.lastSuccess)
        #expect(http.requests.count == 1)
    }

    /// The token that just got a 401 came back from the forced refresh: there is no newer one to try yet.
    @Test(arguments: [(true, AccountStatus.waitingForClaudeCode), (false, .offline)])
    func rejectedTokenIsNotRetried(isTerminal: Bool, expected: AccountStatus) async {
        let creds = FakeCredentials()
        creds.unchangedWhenForced = [b.id]
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}"), ok])
        let states = await poller(http, creds, initial: cached)
            .refresh(accounts: [b], terminalID: isTerminal ? b.id : nil)
        #expect(states[b.id]?.status == expected)
        #expect(states[b.id]?.isStale == true)
        #expect(states[b.id]?.snapshot == .fake())
        #expect(creds.calls.map(\.force) == [false, true])
        #expect(http.requests.count == 1)
    }

    @Test(arguments: [RefreshError.refreshDisabled, .network("-1009"), .http(500)])
    func refreshTroubleKeepsSnapshotWithoutAskingToSignIn(error: RefreshError) async {
        let creds = FakeCredentials()
        creds.errors[b.id] = error
        let states = await poller(FakeHTTPClient([]), creds, initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .offline)
        #expect(states[b.id]?.isStale == true)
        #expect(states[b.id]?.snapshot == .fake())
    }

    @Test func rateLimitBacksOffUntilForced() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}"), ok])
        let p = poller(http, FakeCredentials(), initial: cached)
        let first = await p.refresh(accounts: [b], terminalID: nil)
        #expect(first[b.id]?.status == .rateLimited)
        #expect(first[b.id]?.backoffUntil == clock.now().addingTimeInterval(60))
        #expect(first[b.id]?.snapshot == .fake())
        _ = await p.refresh(accounts: [b], terminalID: nil)
        #expect(http.requests.count == 1)
        let forced = await p.refresh(accounts: [b], terminalID: nil, force: true)
        #expect(forced[b.id]?.status == .ok)
        #expect(forced[b.id]?.consecutiveRateLimits == 0)
    }

    @Test func secondRateLimitDoublesTheBackoff() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}"), FakeHTTPClient.json(429, "{}")])
        let p = poller(http, FakeCredentials())
        _ = await p.refresh(accounts: [b], terminalID: nil)
        let second = await p.refresh(accounts: [b], terminalID: nil, force: true)
        #expect(second[b.id]?.consecutiveRateLimits == 2)
        #expect(second[b.id]?.backoffUntil == clock.now().addingTimeInterval(120))
    }

    @Test func retryAfterHeaderExtendsBackoff() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}", headers: ["Retry-After": "300"])])
        let states = await poller(http, FakeCredentials()).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.backoffUntil == clock.now().addingTimeInterval(300))
    }

    @Test(arguments: [("99999999", 3_600.0), ("inf", 60), ("nan", 60)])
    func retryAfterIsBounded(header: String, wait: TimeInterval) async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}", headers: ["Retry-After": header])])
        let states = await poller(http, FakeCredentials()).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.backoffUntil == clock.now().addingTimeInterval(wait))
    }

    @Test func networkErrorMarksOfflineAndStale() async {
        let http = FakeHTTPClient([])
        http.error = URLError(.notConnectedToInternet)
        let states = await poller(http, FakeCredentials(), initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .offline)
        #expect(states[b.id]?.isStale == true)
        #expect(states[b.id]?.snapshot == .fake())
    }

    /// The test's task cancels itself during the first request; URLSession then reports a cancelled request.
    @Test func cancelledRefreshKeepsPreviousStates() async {
        let a = Account.fake("A")
        var initial = cached
        initial[a.id] = cached[b.id]
        let http = FakeHTTPClient([])
        http.error = URLError(.cancelled)
        http.onSend = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let p = poller(http, FakeCredentials(), initial: initial)
        let states = await Task { await p.refresh(accounts: [b, a], terminalID: nil) }.value
        #expect(states == initial)
        #expect(await p.currentStates() == initial)
        #expect(http.requests.count == 1)
    }

    @Test func cancelledCallerStartsNoRequests() async {
        let http = FakeHTTPClient([ok])
        let creds = FakeCredentials()
        let p = poller(http, creds, initial: cached)
        let states = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await p.refresh(accounts: [b], terminalID: nil)
        }.value
        #expect(states == cached)
        #expect(creds.calls.isEmpty)
        #expect(http.requests.isEmpty)
    }

    /// A refresh that already reached the token endpoint must finish and save the rotated token.
    @Test func cancellationDoesNotReachTheTokenCall() async {
        let creds = FakeCredentials()
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}"), ok])
        http.onSend = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        _ = await Task { await poller(http, creds).refresh(accounts: [b], terminalID: nil) }.value
        #expect(creds.calls.map(\.force) == [false, true])
        #expect(creds.calls.map(\.cancelled) == [false, false])
    }

    @Test func overlappingRefreshesShareOneRound() async {
        let http = FakeHTTPClient([ok])
        http.onSend = { _ in usleep(100_000) }   // keeps the first round in flight while the second call arrives
        let creds = FakeCredentials()
        let p = poller(http, creds)
        async let first = p.refresh(accounts: [b], terminalID: nil)
        async let second = p.refresh(accounts: [b], terminalID: nil)
        let (one, two) = await (first, second)
        #expect(http.requests.count == 1)
        #expect(creds.calls.count == 1)
        #expect(one[b.id]?.status == .ok)
        #expect(two == one)
    }

    @Test func windowResetSinceFetchIsOutdatedAndNotRecommended() {
        let now = clock.now()
        let earlier = now.addingTimeInterval(-7_200)
        let reset = AccountRefreshState(snapshot: .fake(session: 0, weekly: 0, fable: 0,
                                                        sessionResets: now.addingTimeInterval(-60), fetchedAt: earlier),
                                        lastSuccess: earlier, status: .ok, consecutiveRateLimits: 0,
                                        backoffUntil: nil, isStale: false)
        #expect(reset.isOutdated(at: now))
        #expect(!reset.isOutdated(at: now.addingTimeInterval(-120)))
        var fetchedAfterReset = reset
        fetchedAfterReset.snapshot?.fetchedAt = now
        #expect(!fetchedAfterReset.isOutdated(at: now))

        let current = cached[b.id]
        #expect(Recommender.best([
            RecommendationCandidate(accountID: "reset", state: reset, isTerminal: false, now: now),
            RecommendationCandidate(accountID: "current", state: current, isTerminal: false, now: now),
        ], preferredModel: nil) == "current")
        #expect(RecommendationCandidate(accountID: "current", state: current, isTerminal: false, now: now).isAvailable)
        var waiting = current
        waiting?.status = .waitingForClaudeCode
        #expect(!RecommendationCandidate(accountID: "w", state: waiting, isTerminal: false, now: now).isAvailable)
        #expect(!RecommendationCandidate(accountID: "new", state: nil, isTerminal: false, now: now).isAvailable)
    }

    @Test func unreadableClaudeJSONKeepsPollingTheOtherAccounts() async throws {
        let dir = try TempDir()
        let (store, terminal) = try workspace(dir)
        let a = "acc-A:org-A"
        let creds = FakeCredentials()
        let p = poller(FakeHTTPClient([ok, ok, ok]), creds)
        let first = try await p.poll(store: store, terminal: terminal)
        #expect(first.terminalID == a)
        #expect(first.terminalError == nil)
        #expect(first.accounts.map(\.id) == [b.id, a])
        #expect(creds.calls.map(\.isTerminal) == [false, true])

        try Data(#"{"mcpServers": {"x": {"env": {"TOKEN": "sk-secret-value"}}}, "oauthAccount": {"#.utf8).write(to: terminal.url)
        let second = try await p.poll(store: store, terminal: terminal)
        let message = try #require(second.terminalError)
        #expect(message.contains(".claude.json"))
        #expect(!message.contains("sk-secret"))
        #expect(second.terminalID == a)
        #expect(creds.calls.map(\.id) == [b.id, a, b.id])
        #expect(second.states[b.id]?.status == .ok)
        #expect(second.states[a]?.isStale == true)
        #expect(second.states[a]?.snapshot == first.states[a]?.snapshot)
    }

    @Test func unreadableClaudeJSONBeforeAnyReadRefreshesNobody() async throws {
        let dir = try TempDir()
        let (store, terminal) = try workspace(dir)
        try Data("not json".utf8).write(to: terminal.url)
        let http = FakeHTTPClient([])
        let creds = FakeCredentials()
        let result = try await poller(http, creds, initial: cached).poll(store: store, terminal: terminal)
        #expect(result.terminalError != nil)
        #expect(result.terminalID == nil)
        #expect(result.accounts.map(\.id) == [b.id])
        #expect(creds.calls.isEmpty)
        #expect(http.requests.isEmpty)
        #expect(result.states[b.id]?.snapshot == .fake())
        #expect(result.states[b.id]?.isStale == true)
    }

    @Test func skippedAccountWithoutCacheKeepsItsStoredStatus() async throws {
        let dir = try TempDir()
        let (store, terminal) = try workspace(dir)
        try store.update(id: b.id) { $0.status = .needsSignIn }
        try Data("not json".utf8).write(to: terminal.url)
        let result = try await poller(FakeHTTPClient([]), FakeCredentials()).poll(store: store, terminal: terminal)
        #expect(result.states[b.id]?.status == .needsSignIn)
        #expect(result.states[b.id]?.snapshot == nil)
        #expect(result.states[b.id]?.isStale == false)
    }

    @Test func readErrorAfterReadingNoTerminalAccountPollsEveryoneAsAppOwned() async throws {
        let dir = try TempDir()
        let (store, terminal) = try workspace(dir)
        try Data(#"{"numStartups": 3}"#.utf8).write(to: terminal.url)
        let creds = FakeCredentials()
        let p = poller(FakeHTTPClient([ok, ok]), creds)
        let first = try await p.poll(store: store, terminal: terminal)
        #expect(first.terminalID == nil)
        #expect(first.terminalError == nil)

        try Data("not json".utf8).write(to: terminal.url)
        let second = try await p.poll(store: store, terminal: terminal)
        #expect(second.terminalError != nil)
        #expect(second.terminalID == nil)
        #expect(creds.calls.map(\.id) == [b.id, b.id])
        #expect(creds.calls.map(\.isTerminal) == [false, false])
        #expect(second.states[b.id]?.status == .ok)
        #expect(second.states[b.id]?.isStale == false)
    }

    @Test func accountListWriteFailureIsNotBlamedOnClaudeJSON() async throws {
        let dir = try TempDir()
        let folder = dir.url.appendingPathComponent("support", isDirectory: true)
        let store = AccountStore(fileURL: folder.appendingPathComponent("accounts.json"), secrets: InMemorySecretStore())
        try store.upsert(b)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "a@example.com").utf8).write(to: dir.file(".claude.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let creds = FakeCredentials()
        let result = try await poller(FakeHTTPClient([ok]), creds)
            .poll(store: store, terminal: TerminalAccountFile(url: dir.file(".claude.json")))
        let message = try #require(result.terminalError)
        #expect(!message.contains(".claude.json"))
        #expect(message.contains("accounts.json"))
        #expect(result.terminalID == "acc-A:org-A")
        #expect(result.accounts.map(\.id) == [b.id])
        #expect(creds.calls.map(\.id) == [b.id])
    }

    @Test func unreadableAccountListThrows() async throws {
        let dir = try TempDir()
        let (store, terminal) = try workspace(dir)
        try Data("garbage".utf8).write(to: dir.file("accounts.json"))
        let p = poller(FakeHTTPClient([]), FakeCredentials())
        await #expect(throws: (any Error).self) { try await p.poll(store: store, terminal: terminal) }
    }

    @Test func refreshOnOpenRule() {
        let now = clock.now()
        #expect(Poller.shouldRefreshOnOpen(lastSuccess: nil, now: now))
        #expect(!Poller.shouldRefreshOnOpen(lastSuccess: now.addingTimeInterval(-30), now: now))
        #expect(Poller.shouldRefreshOnOpen(lastSuccess: now.addingTimeInterval(-90), now: now))
    }

    @Test func backoffDelays() {
        #expect([1, 2, 3, 4, 5, 9].map { Backoff.delay(afterConsecutiveRateLimits: $0) } == [60, 120, 240, 480, 900, 900])
    }

    @Test func stateCacheRoundTrips() throws {
        let dir = try TempDir()
        try StateCache.save(cached, to: dir.file("snapshots.json"))
        #expect(StateCache.load(from: dir.file("snapshots.json")) == cached)
        #expect(StateCache.load(from: dir.file("missing.json")).isEmpty)
    }

    @Test func stateCacheCreatesItsFolderAndIgnoresACorruptFile() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("support/snapshots.json")
        try StateCache.save(cached, to: file)
        #expect(StateCache.load(from: file) == cached)
        try Data("{".utf8).write(to: file)
        #expect(StateCache.load(from: file).isEmpty)
    }
}
