import Foundation
import Testing
@testable import UsageCore

struct LoginFlowTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    static let studioProfile = Fixtures.profileJSON(accountUuid: "acc-N", email: "studio@example.com",
                                                    orgUuid: "org-N", orgName: "Studio")

    func make(_ runner: FakeProcessRunner, secrets: any SecretStore, dir: TempDir,
              profile: String = LoginFlowTests.studioProfile,
              http: FakeHTTPClient? = nil) -> (LoginFlow, AccountStore, URL) {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: secrets)
        let api = UsageAPI(http: http ?? FakeHTTPClient([FakeHTTPClient.json(200, profile)]), now: now)
        let workRoot = dir.url.appendingPathComponent("login", isDirectory: true)
        let flow = LoginFlow(claude: URL(fileURLWithPath: "/usr/local/bin/claude"), runner: runner, secrets: secrets,
                             api: api, store: store, workRoot: workRoot, keychainAccount: "tester",
                             terminalFile: TerminalAccountFile(url: dir.file("terminal.claude.json")), now: now,
                             loginPATH: { "/test/bin" }, baseEnvironment: baseEnvironment)
        return (flow, store, workRoot)
    }

    var baseEnvironment: [String: String] {
        ["HOME": "/Users/x", "PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k",
         "ANTHROPIC_AUTH_TOKEN": "a", "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/old"]
    }

    func leftovers(_ workRoot: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: workRoot.path)) ?? []
    }

    @Test func arguments() {
        #expect(LoginFlow.arguments(for: .google) == ["auth", "login"])
        #expect(LoginFlow.arguments(for: .email("a@b.co")) == ["auth", "login", "--email", "a@b.co"])
    }

    @Test func signInStoresAccountAndCleansUp() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "N", email: "studio@example.com")),
                                       secrets: secrets)
        let (flow, store, workRoot) = make(runner, secrets: secrets, dir: dir)
        let account = try await flow.addAccount(method: .email("studio@example.com"))

        #expect(account.id == "acc-N:org-N")
        #expect(account.email == "studio@example.com")
        #expect(account.label == "Studio")
        #expect(account.status == .ok)
        #expect(account.oauthAccountJSON != nil)
        #expect(try store.credentials(for: account.id) == .fake("N"))
        #expect(secrets.allKeys == ["Claude Usage|acc-N:org-N"])
        #expect(leftovers(workRoot).isEmpty)
        let call = try #require(runner.recorded.first)
        #expect(call.arguments == ["auth", "login", "--email", "studio@example.com"])
        #expect(call.environment["CLAUDE_CONFIG_DIR"]?.hasPrefix(workRoot.path) == true)
    }

    @Test func reLoginKeepsLabelAndClearsNeedsSignIn() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("A2"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "A", email: "a@example.com")),
                                       secrets: secrets)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir,
                                    profile: Fixtures.profileJSON(accountUuid: "acc-A", email: "a@example.com", orgUuid: "org-A"))
        try store.upsert(.fake("A", label: "Work", status: .needsSignIn))
        let account = try await flow.addAccount(method: .google)
        #expect(account.label == "Work")
        #expect(account.status == .ok)
        #expect(try store.load().count == 1)
        #expect(try store.credentials(for: "acc-A:org-A") == .fake("A2"))
    }

    @Test(arguments: [
        (FakeProcessRunner.Behavior.exit(1), LoginError.failed(exitCode: 1)),
        (FakeProcessRunner.Behavior.exit(0), LoginError.noCredentials),
        (FakeProcessRunner.Behavior.fail(CancellationError()), LoginError.cancelled),
        (FakeProcessRunner.Behavior.fail(ProcessRunnerError.timedOut), LoginError.timedOut),
    ])
    func failuresCleanUp(behavior: FakeProcessRunner.Behavior, expected: LoginError) async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let (flow, store, workRoot) = make(FakeProcessRunner(behavior, secrets: secrets), secrets: secrets, dir: dir)
        await #expect(throws: expected) { _ = try await flow.addAccount(method: .google) }
        #expect(leftovers(workRoot).isEmpty)
        #expect(secrets.allKeys.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func locatorPrefersPathThenKnownLocations() {
        let home = URL(fileURLWithPath: "/Users/x")
        let candidates = ClaudeBinaryLocator.candidates(home: home, pathEnv: "/opt/homebrew/bin:/usr/bin")
        #expect(candidates.map(\.path) == ["/opt/homebrew/bin/claude", "/usr/bin/claude", "/Users/x/.local/bin/claude",
                                           "/Users/x/.claude/local/claude", "/usr/local/bin/claude"])
        let found = ClaudeBinaryLocator.locate(home: home, pathEnv: "/usr/bin") { $0 == "/Users/x/.local/bin/claude" }
        #expect(found?.path == "/Users/x/.local/bin/claude")
        #expect(ClaudeBinaryLocator.locate(home: home, pathEnv: nil) { _ in false } == nil)
    }
}

extension LoginFlowTests {
    @Test func invalidClaudeJSONIsALoginFailureAndCleansUp() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: "}{"), secrets: secrets)
        let (flow, store, workRoot) = make(runner, secrets: secrets, dir: dir)
        await #expect(throws: LoginError.noCredentials) { _ = try await flow.addAccount(method: .google) }
        #expect(leftovers(workRoot).isEmpty)
        #expect(secrets.allKeys.isEmpty)
        #expect(try store.load().isEmpty)
    }
}

/// Wraps a store and fails selected operations.
struct SelectiveFailingStore: SecretStore {
    let inner: InMemorySecretStore
    var failReadService: String?
    var failWriteService: String?

    func read(service: String, account: String) throws -> Data? {
        if let failReadService, service.hasPrefix(failReadService) {
            throw SecretStoreError.commandFailed(operation: "read", status: 1)
        }
        return try inner.read(service: service, account: account)
    }

    func write(service: String, account: String, data: Data) throws {
        if service == failWriteService { throw SecretStoreError.commandFailed(operation: "write", status: 1) }
        try inner.write(service: service, account: account, data: data)
    }

    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

extension LoginFlowTests {
    @Test func keychainReadErrorSurfacesAsItself() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let secrets = SelectiveFailingStore(inner: inner, failReadService: ClaudeCodeKeychain.baseService)
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "N", email: "s@example.com")),
                                       secrets: inner)
        let (flow, store, workRoot) = make(runner, secrets: secrets, dir: dir)
        await #expect(throws: SecretStoreError.commandFailed(operation: "read", status: 1)) {
            _ = try await flow.addAccount(method: .google)
        }
        #expect(leftovers(workRoot).isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func launchFailureIsCouldNotLaunch() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.fail(CocoaError(.fileNoSuchFile)), secrets: secrets)
        let (flow, _, workRoot) = make(runner, secrets: secrets, dir: dir)
        await #expect(throws: LoginError.couldNotLaunch) { _ = try await flow.addAccount(method: .google) }
        #expect(leftovers(workRoot).isEmpty)
    }

    @Test func cancellationDuringProfileCallIsCancelled() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "N", email: "s@example.com")),
                                       secrets: secrets)
        let http = FakeHTTPClient([])
        http.error = URLError(.cancelled)
        let (flow, store, workRoot) = make(runner, secrets: secrets, dir: dir, http: http)
        await #expect(throws: LoginError.cancelled) { _ = try await flow.addAccount(method: .google) }
        #expect(leftovers(workRoot).isEmpty)
        #expect(secrets.allKeys.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func mismatchedLoginIdentityIsNotStored() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "X", email: "x@example.com")),
                                       secrets: secrets)
        let (flow, _, _) = make(runner, secrets: secrets, dir: dir)
        let account = try await flow.addAccount(method: .google)
        let payload = try #require(account.oauthAccountJSON)
        #expect(TerminalAccountFile.identity(fromOAuthAccountJSON: payload)?.accountID == "acc-N:org-N")
        #expect(!String(decoding: payload, as: UTF8.self).contains("acc-X"))
    }

    @Test func failedCredentialWriteLeavesNoAccount() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let secrets = SelectiveFailingStore(inner: inner, failWriteService: AccountStore.keychainService)
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "N", email: "s@example.com")),
                                       secrets: inner)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir)
        await #expect(throws: SecretStoreError.commandFailed(operation: "write", status: 1)) {
            _ = try await flow.addAccount(method: .google)
        }
        #expect(try store.load().isEmpty)
    }

    @Test func failedCredentialWriteKeepsNeedsSignIn() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let secrets = SelectiveFailingStore(inner: inner, failWriteService: AccountStore.keychainService)
        let runner = FakeProcessRunner(.signIn(.fake("A2"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "A", email: "a@example.com")),
                                       secrets: inner)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir,
                                    profile: Fixtures.profileJSON(accountUuid: "acc-A", email: "a@example.com", orgUuid: "org-A"))
        try store.upsert(.fake("A", status: .needsSignIn))
        await #expect(throws: SecretStoreError.self) { _ = try await flow.addAccount(method: .google) }
        #expect(try store.account(id: "acc-A:org-A")?.status == .needsSignIn)
    }

    @Test func childEnvironmentIsCleanedAndHasPath() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.exit(1), secrets: secrets)
        let (flow, _, workRoot) = make(runner, secrets: secrets, dir: dir)
        _ = try? await flow.addAccount(method: .google)
        let env = try #require(runner.recorded.first).environment
        for name in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE"] {
            #expect(env[name] == nil)
        }
        #expect(env["PATH"] == "/test/bin")
        #expect(env["HOME"] == "/Users/x")
        #expect(env["CLAUDE_CONFIG_DIR"]?.hasPrefix(workRoot.path) == true)
    }

    @Test func childEnvironmentFallbackPath() {
        let env = LoginFlow.childEnvironment(base: ["PATH": "/usr/bin"], loginPATH: nil,
                                             home: URL(fileURLWithPath: "/Users/x"), configDir: "/c")
        #expect(env["PATH"] == "/usr/bin:/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/c")
    }

    @Test func sweepRemovesLeftoverDirsAndItems() throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let (flow, _, workRoot) = make(FakeProcessRunner(.exit(0), secrets: secrets), secrets: secrets, dir: dir)
        for name in ["one", "two"] {
            let d = workRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try secrets.write(service: ClaudeCodeKeychain.serviceName(configDir: d.path), account: "tester", data: Data("x".utf8))
        }
        try secrets.write(service: ClaudeCodeKeychain.baseService, account: "tester", data: Data("keep".utf8))
        flow.sweepLeftovers()
        #expect(leftovers(workRoot).isEmpty)
        #expect(secrets.allKeys == ["Claude Code-credentials|tester"])
    }

    func terminalSetup(dir: TempDir, secrets: InMemorySecretStore, terminalTag: String) throws -> Data {
        try Data(ClaudeJSONFixture.file(tag: terminalTag, email: "\(terminalTag.lowercased())@example.com").utf8)
            .write(to: dir.file("terminal.claude.json"))
        let old = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old","expiresAt":1,"scopes":[],"future":true},"mcpOAuth":{"srv":{"k":1}}}"#.utf8)
        try secrets.write(service: ClaudeCodeKeychain.baseService, account: "tester", data: old)
        return old
    }

    @Test func loginAsTheTerminalAccountUpdatesClaudeCodesItem() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        _ = try terminalSetup(dir: dir, secrets: secrets, terminalTag: "A")
        let runner = FakeProcessRunner(.signIn(.fake("A2"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "A", email: "a@example.com")),
                                       secrets: secrets)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir,
                                    profile: Fixtures.profileJSON(accountUuid: "acc-A", email: "a@example.com", orgUuid: "org-A"))
        try store.upsert(.fake("A", status: .needsSignIn))
        let account = try await flow.addAccount(method: .google)

        #expect(account.status == .ok)
        let raw = try #require(try secrets.read(service: ClaudeCodeKeychain.baseService, account: "tester"))
        #expect(try CredentialsJSON.claudeAiOauth(from: raw) == .fake("A2"))
        let o = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(o["mcpOAuth"] as? NSDictionary == ["srv": ["k": 1]])
        #expect((o["claudeAiOauth"] as? [String: Any])?["future"] as? Bool == true)
        #expect(try store.credentials(for: "acc-A:org-A") == nil)
    }

    @Test func loginAsAnotherAccountLeavesClaudeCodesItemAlone() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let old = try terminalSetup(dir: dir, secrets: secrets, terminalTag: "B")
        let runner = FakeProcessRunner(.signIn(.fake("A2"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "A", email: "a@example.com")),
                                       secrets: secrets)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir,
                                    profile: Fixtures.profileJSON(accountUuid: "acc-A", email: "a@example.com", orgUuid: "org-A"))
        _ = try await flow.addAccount(method: .google)
        #expect(try secrets.read(service: ClaudeCodeKeychain.baseService, account: "tester") == old)
        #expect(try store.credentials(for: "acc-A:org-A") == .fake("A2"))
    }
}
