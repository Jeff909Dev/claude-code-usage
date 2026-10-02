import Foundation
import Testing
@testable import UsageCore

struct AccountSwitcherTests {
    let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    static let mcp = Data(#"{"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8)

    struct World {
        let dir: TempDir
        let secrets: InMemorySecretStore
        let store: AccountStore
        let file: TerminalAccountFile
        let claudeURL: URL
        let switcher: AccountSwitcher
    }

    /// Terminal on account A (Claude Code has refreshed its token: "A-refreshed"); B is app-owned.
    func world(claudeJSON: String? = nil, listA: Bool = true) throws -> World {
        let dir = try TempDir()
        try FileManager.default.createDirectory(at: dir.file("home"), withIntermediateDirectories: true)
        let claudeURL = dir.file("home/.claude.json")
        let secrets = InMemorySecretStore()
        try Data((claudeJSON ?? ClaudeJSONFixture.file(tag: "A", email: "a@example.com")).utf8).write(to: claudeURL)
        try secrets.write(service: item.service, account: item.account,
                          data: CredentialsJSON.merging(.fake("A-refreshed"), into: Self.mcp))
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: secrets)
        if listA { try store.upsert(.fake("A")) }
        try store.upsert(.fake("B"))
        try store.setCredentials(.fake("B"), for: Account.fake("B").id)
        let file = TerminalAccountFile(url: claudeURL)
        return World(dir: dir, secrets: secrets, store: store, file: file, claudeURL: claudeURL,
                     switcher: AccountSwitcher(store: store, secrets: secrets, terminalItem: item, terminalFile: file, now: now))
    }

    static var mcpObject: NSDictionary { ["linear": ["accessToken": "m1"]] }

    func mcp(_ raw: Data) throws -> NSDictionary? {
        (try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["mcpOAuth"] as? NSDictionary
    }

    func terminalCreds(_ w: World) throws -> OAuthCredentials? {
        try w.secrets.read(service: item.service, account: item.account).flatMap(CredentialsJSON.claudeAiOauth(from:))
    }

    @Test func switchesKeychainAndClaudeJSONAndSavesOutgoing() throws {
        let w = try world()
        let result = try w.switcher.switchTerminal(to: Account.fake("B").id)
        #expect(result == SwitchResult(fromID: "acc-A:org-A", toID: "acc-B:org-B"))
        #expect(try terminalCreds(w) == .fake("B"))
        let raw = try #require(try w.secrets.read(service: item.service, account: item.account))
        #expect(try mcp(raw) == Self.mcpObject)
        #expect(try w.file.currentIdentity()?.accountID == "acc-B:org-B")
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-refreshed"))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: w.claudeURL)) as? [String: Any])
        #expect(o["numStartups"] as? Int == 7)
    }

    @Test func targetDoesNotInheritTheOutgoingLoginsUnmodelledKeys() throws {
        let w = try world()
        let item = Data(#"{"claudeAiOauth":{"accessToken":"at-A-refreshed","refreshToken":"rt-A-refreshed","expiresAt":1790907890004,"scopes":["user:inference"],"future":{"x":1}},"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8)
        try w.secrets.write(service: self.item.service, account: self.item.account, data: item)
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        let raw = try #require(try w.secrets.read(service: self.item.service, account: self.item.account))
        let oauth = try #require((try JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["future"] == nil)
        #expect(try terminalCreds(w) == .fake("B"))
        #expect(try mcp(raw) == Self.mcpObject)
    }

    @Test func switchingBackRestoresTheOriginalAccount() throws {
        let w = try world()
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        try w.switcher.switchTerminal(to: Account.fake("A").id)
        #expect(try terminalCreds(w) == .fake("A-refreshed"))
        #expect(try w.file.currentIdentity()?.accountID == "acc-A:org-A")
        #expect(try w.store.credentials(for: "acc-B:org-B") == .fake("B"))
    }

    @Test func refusesActiveMissingOrSignedOutTargets() throws {
        let w = try world()
        #expect(throws: SwitchError.alreadyActive) { try w.switcher.switchTerminal(to: "acc-A:org-A") }
        #expect(throws: SwitchError.unknownAccount) { try w.switcher.switchTerminal(to: "nope") }
        try w.store.upsert(.fake("C"))
        #expect(throws: SwitchError.missingCredentials) { try w.switcher.switchTerminal(to: "acc-C:org-C") }
        try w.store.update(id: "acc-B:org-B") { $0.status = .needsSignIn }
        #expect(throws: SwitchError.needsSignIn) { try w.switcher.switchTerminal(to: "acc-B:org-B") }
        #expect(try terminalCreds(w) == .fake("A-refreshed"))
    }

    @Test func unlistedTerminalAccountIsImportedBeforeSwitching() throws {
        let w = try world(listA: false)
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        #expect(try w.store.account(id: "acc-A:org-A") != nil)
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-refreshed"))
    }

    @Test func signedOutTerminalItemDoesNotOverwriteOutgoingAppCredentials() throws {
        let w = try world()
        try w.store.setCredentials(.fake("A-old"), for: "acc-A:org-A")
        try w.secrets.write(service: item.service, account: item.account, data: Data(#"{"claudeAiOauth":null,"mcpOAuth":{}}"#.utf8))
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-old"))
        #expect(try terminalCreds(w) == .fake("B"))
    }

    @Test func rollbackDeletesTheItemWhenItDidNotExistBefore() throws {
        let w = try world(claudeJSON: "[]")
        try w.secrets.delete(service: item.service, account: item.account)
        #expect(throws: TerminalAccountError.notAnObject) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == nil)
    }

    // MARK: safety

    /// Makes ~/.claude.json's directory read-only so the write fails; restores it for cleanup.
    func lockClaudeDirectory(_ w: World) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: w.dir.file("home").path)
    }

    func unlockClaudeDirectory(_ w: World) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.dir.file("home").path)
    }

    @Test func rollsBackKeychainWhenClaudeJSONCannotBeWritten() throws {
        let w = try world()
        let itemBefore = try w.secrets.read(service: item.service, account: item.account)
        let fileBefore = try Data(contentsOf: w.claudeURL)
        try lockClaudeDirectory(w)
        defer { unlockClaudeDirectory(w) }
        #expect(throws: (any Error).self) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == itemBefore)
        #expect(try Data(contentsOf: w.claudeURL) == fileBefore)
        #expect(try mcp(try #require(itemBefore)) == Self.mcpObject)
    }

    @Test func rollbackIsRetriedOnceThenReported() throws {
        for (failures, expectRollbackFailed) in [(1, false), (2, true)] {
            let w = try world()
            let flaky = FlakySecretStore(w.secrets, key: item, failWritesAfter: 1, failures: failures)
            let switcher = AccountSwitcher(store: w.store, secrets: flaky, terminalItem: item, terminalFile: w.file, now: now)
            let before = try w.secrets.read(service: item.service, account: item.account)
            try lockClaudeDirectory(w)
            defer { unlockClaudeDirectory(w) }
            do {
                try switcher.switchTerminal(to: Account.fake("B").id)
                Issue.record("expected a failure")
            } catch let error as SwitchError {
                #expect(expectRollbackFailed)
                guard case .rollbackFailed = error else { Issue.record("wrong case"); continue }
                #expect(try w.secrets.read(service: item.service, account: item.account) != before)
            } catch {
                #expect(!expectRollbackFailed)
                #expect(try w.secrets.read(service: item.service, account: item.account) == before)
            }
        }
    }

    func scripted(_ w: World, _ steps: [Int: ScriptedWriteStore.Step]) -> (ScriptedWriteStore, AccountSwitcher) {
        let secrets = ScriptedWriteStore(w.secrets, key: item, steps: steps)
        return (secrets, AccountSwitcher(store: w.store, secrets: secrets, terminalItem: item, terminalFile: w.file, now: now))
    }

    @Test func failedHandOverThatStoredTheTargetIsUndone() throws {
        let w = try world()
        let before = try w.secrets.read(service: item.service, account: item.account)
        let fileBefore = try Data(contentsOf: w.claudeURL)
        let (_, switcher) = scripted(w, [1: .failAfterStoring])
        #expect(throws: SecretStoreError.verificationFailed(operation: "write")) {
            try switcher.switchTerminal(to: Account.fake("B").id)
        }
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
        #expect(try Data(contentsOf: w.claudeURL) == fileBefore)
    }

    @Test func failedHandOverThatStoredNothingLeavesTheItemAlone() throws {
        let w = try world()
        let before = try w.secrets.read(service: item.service, account: item.account)
        let (secrets, switcher) = scripted(w, [1: .failBeforeStoring])
        #expect(throws: SecretStoreError.verificationFailed(operation: "write")) {
            try switcher.switchTerminal(to: Account.fake("B").id)
        }
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
        #expect(secrets.terminalWrites == 1)
    }

    @Test func failedHandOverKeepsATokenClaudeCodeWroteMeanwhile() throws {
        let w = try world()
        let rotated = try CredentialsJSON.merging(.fake("A-rotated"), into: Self.mcp)
        let (_, switcher) = scripted(w, [1: .storedThenReplacedBy(rotated, fail: true)])
        #expect(throws: SecretStoreError.verificationFailed(operation: "write")) {
            try switcher.switchTerminal(to: Account.fake("B").id)
        }
        #expect(try w.secrets.read(service: item.service, account: item.account) == rotated)
    }

    @Test func failedClaudeJSONWriteKeepsATokenClaudeCodeWroteMeanwhile() throws {
        let w = try world()
        let rotated = try CredentialsJSON.merging(.fake("A-rotated"), into: Self.mcp)
        let (_, switcher) = scripted(w, [1: .storedThenReplacedBy(rotated, fail: false)])
        try lockClaudeDirectory(w)
        defer { unlockClaudeDirectory(w) }
        #expect(throws: (any Error).self) { try switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == rotated)
    }

    @Test func refusesWhenDefaultItemHoldsAnotherListedAccountsToken() throws {
        let w = try world()
        try w.secrets.write(service: item.service, account: item.account,
                            data: CredentialsJSON.merging(.fake("B"), into: Self.mcp))
        let before = try w.secrets.read(service: item.service, account: item.account)
        try w.store.setCredentials(.fake("A-old"), for: "acc-A:org-A")
        #expect(throws: SwitchError.inconsistentTerminal) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-old"))
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
    }

    @Test func tokenRotatedBetweenReadAndWriteIsKept() throws {
        let w = try world()
        let rotating = RotatingSecretStore(w.secrets, key: item) { n in
            n == 1 ? try CredentialsJSON.merging(.fake("A-rotated"), into: Data(#"{"mcpOAuth":{"linear":{"accessToken":"m2"}}}"#.utf8)) : nil
        }
        let switcher = AccountSwitcher(store: w.store, secrets: rotating, terminalItem: item, terminalFile: w.file, now: now)
        try switcher.switchTerminal(to: Account.fake("B").id)
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-rotated"))
        let raw = try #require(try w.secrets.read(service: item.service, account: item.account))
        #expect(try mcp(raw) == ["linear": ["accessToken": "m2"]] as NSDictionary)
        #expect(try terminalCreds(w) == .fake("B"))
    }

    @Test func givesUpWhenTheItemKeepsChanging() throws {
        let w = try world()
        let rotating = RotatingSecretStore(w.secrets, key: item) { n in
            n % 2 == 1 ? try CredentialsJSON.merging(.fake("A-\(n)"), into: Self.mcp) : nil
        }
        let switcher = AccountSwitcher(store: w.store, secrets: rotating, terminalItem: item, terminalFile: w.file, now: now)
        #expect(throws: SwitchError.terminalChanging) { try switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.file.currentIdentity()?.accountID == "acc-A:org-A")
    }

    @Test func targetPayloadMustMatchTheTargetIdentity() throws {
        let w = try world()
        var b = Account.fake("B")
        b.oauthAccountJSON = Data(ClaudeJSONFixture.oauthAccount(tag: "X", email: "x@example.com").utf8)
        try w.store.upsert(b)
        let before = try w.secrets.read(service: item.service, account: item.account)
        #expect(throws: TerminalAccountError.invalidReplacement) { try w.switcher.switchTerminal(to: b.id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
    }

    @Test func refusesToDropALoginWhenClaudeJSONNamesNoAccount() throws {
        let w = try world(claudeJSON: #"{"numStartups":1}"#)
        let before = try w.secrets.read(service: item.service, account: item.account)
        #expect(throws: SwitchError.unknownTerminalOwner) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
    }

    @Test func expiredRefreshTokenCountsAsSignedOut() throws {
        let w = try world()
        try w.store.setCredentials(.fake("B", refreshTokenExpiresAt: 1_000), for: "acc-B:org-B")
        #expect(throws: SwitchError.needsSignIn) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try terminalCreds(w) == .fake("A-refreshed"))
    }
}

/// Fails writes to the terminal item (after the first `failWritesAfter` writes) `failures` times.
final class FlakySecretStore: SecretStore, @unchecked Sendable {
    private let inner: InMemorySecretStore
    private let key: TerminalKeychainItem
    private let lock = NSLock()
    private var writes = 0
    private var remaining: Int
    private let after: Int
    struct Boom: Error {}

    init(_ inner: InMemorySecretStore, key: TerminalKeychainItem, failWritesAfter: Int, failures: Int) {
        self.inner = inner; self.key = key; self.after = failWritesAfter; self.remaining = failures
    }

    func read(service: String, account: String) throws -> Data? { try inner.read(service: service, account: account) }

    func write(service: String, account: String, data: Data) throws {
        if service == key.service, account == key.account {
            let fail: Bool = lock.locked {
                writes += 1
                guard writes > after, remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if fail { throw Boom() }
        }
        try inner.write(service: service, account: account, data: data)
    }

    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

/// Scripts the n-th write (from 1) to the terminal item; unscripted writes and other items go straight through.
final class ScriptedWriteStore: SecretStore, @unchecked Sendable {
    enum Step: Sendable {
        /// Nothing was stored.
        case failBeforeStoring
        /// The value was stored, but reading it back did not match.
        case failAfterStoring
        /// The value was stored, then Claude Code wrote `data`; `fail` makes our write report it.
        case storedThenReplacedBy(Data, fail: Bool)
    }

    private let inner: InMemorySecretStore
    private let key: TerminalKeychainItem
    private let steps: [Int: Step]
    private let lock = NSLock()
    private var writes = 0

    init(_ inner: InMemorySecretStore, key: TerminalKeychainItem, steps: [Int: Step]) {
        self.inner = inner; self.key = key; self.steps = steps
    }

    var terminalWrites: Int { lock.locked { writes } }

    func read(service: String, account: String) throws -> Data? { try inner.read(service: service, account: account) }

    func write(service: String, account: String, data: Data) throws {
        guard service == key.service, account == key.account else {
            return try inner.write(service: service, account: account, data: data)
        }
        let n = lock.locked { writes += 1; return writes }
        let failed = SecretStoreError.verificationFailed(operation: "write")
        switch steps[n] {
        case nil:
            try inner.write(service: service, account: account, data: data)
        case .failBeforeStoring:
            throw failed
        case .failAfterStoring:
            try inner.write(service: service, account: account, data: data)
            throw failed
        case .storedThenReplacedBy(let other, let fail):
            try inner.write(service: service, account: account, data: data)
            try inner.write(service: service, account: account, data: other)
            if fail { throw failed }
        }
    }

    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

/// After the n-th read of the terminal item returns, `change(n)` may replace its value (simulating Claude Code).
final class RotatingSecretStore: SecretStore, @unchecked Sendable {
    private let inner: InMemorySecretStore
    private let key: TerminalKeychainItem
    private let change: @Sendable (Int) throws -> Data?
    private let lock = NSLock()
    private var reads = 0

    init(_ inner: InMemorySecretStore, key: TerminalKeychainItem, change: @escaping @Sendable (Int) throws -> Data?) {
        self.inner = inner; self.key = key; self.change = change
    }

    func read(service: String, account: String) throws -> Data? {
        let value = try inner.read(service: service, account: account)
        guard service == key.service, account == key.account else { return value }
        let n = lock.locked { reads += 1; return reads }
        if let next = try change(n) { try inner.write(service: service, account: account, data: next) }
        return value
    }

    func write(service: String, account: String, data: Data) throws { try inner.write(service: service, account: account, data: data) }
    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}
