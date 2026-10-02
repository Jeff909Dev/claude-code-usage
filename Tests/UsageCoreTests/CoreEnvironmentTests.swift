import Foundation
import Testing
@testable import UsageCore

struct CoreEnvironmentTests {
    @Test func wiresTheStatusFlowEndToEnd() async throws {
        let dir = try TempDir()
        let home = dir.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "you@work.example").utf8).write(to: home.appendingPathComponent(".claude.json"))
        let secrets = InMemorySecretStore()
        let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
        try secrets.write(service: item.service, account: item.account,
                          data: CredentialsJSON.merging(.fake("A", expiresAt: 4_102_444_800_000), into: nil))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.usageJSON)])
        let env = CoreEnvironment.make(paths: Paths(home: home, appSupport: dir.url.appendingPathComponent("support")),
                                       secrets: secrets, http: http,
                                       now: FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400)),
                                       terminalItem: item, readOnly: true)

        try TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        #expect(env.terminalAccountID() == "acc-A:org-A")
        let states = await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .refresh(accounts: try env.store.load(), terminalID: env.terminalAccountID())
        #expect(states["acc-A:org-A"]?.snapshot?.limits.map(\.percent) == [25, 54, 64])
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at-A")
        #expect(env.makeLoginFlow(claude: URL(fileURLWithPath: "/bin/true")).workRoot == env.paths.loginWorkRoot)
    }

    /// A terminal account whose token expired an hour before `now`, so polling it wants a refresh.
    func expiredTerminal(_ dir: TempDir, readOnly: Bool, http: FakeHTTPClient)
        throws -> (CoreEnvironment, InMemorySecretStore, original: Data) {
        let home = dir.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "a@example.com").utf8).write(to: home.appendingPathComponent(".claude.json"))
        let now = Date(timeIntervalSince1970: 1_790_870_400)
        let secrets = InMemorySecretStore()
        let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
        let original = try CredentialsJSON.merging(.fake("A", expiresAt: Int64((now.timeIntervalSince1970 - 3_600) * 1_000)),
                                                   into: Data(#"{"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8))
        try secrets.write(service: item.service, account: item.account, data: original)
        let env = CoreEnvironment.make(paths: Paths(home: home, appSupport: dir.url.appendingPathComponent("support")),
                                       secrets: secrets, http: http, now: FixedDateProvider(now),
                                       terminalItem: item, readOnly: readOnly)
        return (env, secrets, original)
    }

    @Test func readOnlyNeverRefreshesATokenOrWritesTheKeychain() async throws {
        let dir = try TempDir()
        let http = FakeHTTPClient([])
        let (env, secrets, original) = try expiredTerminal(dir, readOnly: true, http: http)

        let result = try await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .poll(store: env.store, terminal: env.terminalFile, force: true)
        #expect(result.states["acc-A:org-A"]?.status == .offline)
        #expect(http.requests.isEmpty)
        #expect(secrets.allKeys == ["Claude Code-credentials|tester"])
        #expect(try secrets.read(service: env.terminalItem.service, account: env.terminalItem.account) == original)
    }

    @Test func writableEnvironmentRefreshesAnIdleTerminalToken() async throws {
        let dir = try TempDir()
        let http = FakeHTTPClient([
            FakeHTTPClient.json(200, #"{"access_token":"at-A2","refresh_token":"rt-A2","expires_in":28800}"#),
            FakeHTTPClient.json(200, Fixtures.usageJSON),
        ])
        let (env, secrets, original) = try expiredTerminal(dir, readOnly: false, http: http)

        let result = try await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .poll(store: env.store, terminal: env.terminalFile, force: true)
        #expect(result.states["acc-A:org-A"]?.status == .ok)
        #expect(http.requests.map(\.url) == [OAuthEndpoint.token, URL(string: "https://api.anthropic.com/api/oauth/usage")])
        let raw = try #require(try secrets.read(service: env.terminalItem.service, account: env.terminalItem.account))
        #expect(raw != original)
        #expect(try CredentialsJSON.claudeAiOauth(from: raw)?.refreshToken == "rt-A2")
    }

    @Test func loginFlowSharesTheTerminalsKeychainAccountAndFile() throws {
        let dir = try TempDir()
        let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "someone")
        let env = CoreEnvironment.make(paths: Paths(home: dir.url, appSupport: dir.file("support")),
                                       secrets: InMemorySecretStore(), http: FakeHTTPClient([]),
                                       now: SystemDateProvider(), terminalItem: item, readOnly: false)
        let flow = env.makeLoginFlow(claude: URL(fileURLWithPath: "/bin/true"))
        #expect(flow.keychainAccount == "someone")
        #expect(flow.terminalFile.url == env.paths.claudeJSON)
        #expect(env.switcher.terminalItem == item)
        #expect(env.credentials.terminalItem == item)
    }

    @Test func sweepRemovesLeftoverLoginsUnderTheTerminalsKeychainAccount() throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "someone")
        let env = CoreEnvironment.make(paths: Paths(home: dir.url, appSupport: dir.file("support")), secrets: secrets,
                                       http: FakeHTTPClient([]), now: SystemDateProvider(), terminalItem: item,
                                       readOnly: false)
        let leftover = env.paths.loginWorkRoot.appendingPathComponent("crashed-run", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try secrets.write(service: ClaudeCodeKeychain.serviceName(configDir: leftover.path), account: "someone",
                          data: Data("x".utf8))
        try secrets.write(service: item.service, account: item.account, data: Data("keep".utf8))

        env.sweepLoginLeftovers()
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.loginWorkRoot.path).isEmpty)
        #expect(secrets.allKeys == ["Claude Code-credentials|someone"])
    }

    /// The terminal's account is re-read at removal time: a switch may have moved the terminal since the UI checked.
    @Test func removingAnAccountNeverRemovesTheTerminalsAccount() throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let env = CoreEnvironment.make(paths: Paths(home: dir.url, appSupport: dir.file("support")), secrets: secrets,
                                       http: FakeHTTPClient([]), now: SystemDateProvider(),
                                       terminalItem: TerminalKeychainItem(service: "Claude Code-credentials", account: "t"),
                                       readOnly: false)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "a@example.com").utf8).write(to: env.paths.claudeJSON)
        let (a, b) = (Account.fake("A"), Account.fake("B"))
        try env.store.save([a, b])
        try env.store.setCredentials(.fake("A"), for: a.id)
        try env.store.setCredentials(.fake("B"), for: b.id)

        #expect(throws: RemoveAccountError.inTerminal) { try env.removeAccount(id: a.id) }
        #expect(try env.store.credentials(for: a.id) != nil)

        try Data("not json".utf8).write(to: env.paths.claudeJSON)
        #expect(throws: (any Error).self) { try env.removeAccount(id: b.id) }   // can't tell: keep it
        #expect(try env.store.load().map(\.id) == [a.id, b.id])

        try Data(ClaudeJSONFixture.file(tag: "A", email: "a@example.com").utf8).write(to: env.paths.claudeJSON)
        try env.removeAccount(id: b.id)
        #expect(try env.store.load().map(\.id) == [a.id])
        #expect(try env.store.credentials(for: b.id) == nil)
    }

    @Test func anExecutableCustomClaudePathWins() throws {
        let dir = try TempDir()
        let env = CoreEnvironment.make(paths: Paths(home: dir.url, appSupport: dir.file("support")),
                                       secrets: InMemorySecretStore(), http: FakeHTTPClient([]),
                                       now: SystemDateProvider(), terminalItem: .live(), readOnly: true)
        #expect(env.locateClaude(customPath: "/bin/sh") == URL(fileURLWithPath: "/bin/sh"))
    }

    @Test func readOnlyRunsKeepTheirStateInAScratchCopy() throws {
        let dir = try TempDir()
        let live = Paths(home: dir.file("home"), appSupport: dir.file("support"))
        let scratch = dir.file("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: scratch.appendingPathComponent("accounts.json"))   // from an earlier run

        // The app has never run: nothing of the app's is created, and the earlier run's account list is dropped.
        let first = try CoreEnvironment.readOnlyPaths(from: live, scratch: scratch)
        #expect(first == Paths(home: live.home, appSupport: scratch))
        #expect(!FileManager.default.fileExists(atPath: live.appSupport.path))
        #expect(!FileManager.default.fileExists(atPath: first.accountsFile.path))

        // The app has accounts and a pricing override: each run starts from a copy, and writes stay in the copy.
        let store = AccountStore(fileURL: live.accountsFile, secrets: InMemorySecretStore())
        try store.upsert(.fake("B"))
        let appAccounts = try Data(contentsOf: live.accountsFile)
        try Data(#"{"models":[],"plans":{}}"#.utf8).write(to: live.pricingOverride)
        let second = try CoreEnvironment.readOnlyPaths(from: live, scratch: scratch)
        #expect(try Data(contentsOf: second.accountsFile) == appAccounts)
        #expect(try Data(contentsOf: second.pricingOverride) == Data(contentsOf: live.pricingOverride))
        try AccountStore(fileURL: second.accountsFile, secrets: InMemorySecretStore()).upsert(.fake("C"))
        #expect(try Data(contentsOf: live.accountsFile) == appAccounts)
    }
}
