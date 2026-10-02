import Foundation
import Testing
@testable import UsageCore

struct CredentialProviderTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
    var future: Int64 { Int64((now.now().timeIntervalSince1970 + 3_600) * 1_000) }
    var longExpired: Int64 { Int64((now.now().timeIntervalSince1970 - 600) * 1_000) }
    var nearlyExpired: Int64 { Int64((now.now().timeIntervalSince1970 + 120) * 1_000) }

    func terminalBlob(_ creds: OAuthCredentials) throws -> Data {
        try CredentialsJSON.merging(creds, into: Data(#"{"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8))
    }

    func provider(http: FakeHTTPClient, secrets: InMemorySecretStore, store: AccountStore,
                  allowRefresh: Bool = true) -> CredentialProvider {
        CredentialProvider(store: store, secrets: secrets, terminalItem: item,
                           refresher: TokenRefresher(http: http, now: now), now: now, allowRefresh: allowRefresh)
    }

    @Test func terminalFreshTokenIsReadNotRefreshed() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: future)))
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T")
        #expect(http.requests.isEmpty)
    }

    @Test func terminalExpiredRefreshesAndKeepsMcpOAuth() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        let raw = try #require(try secrets.read(service: item.service, account: item.account))
        #expect(try CredentialsJSON.claudeAiOauth(from: raw)?.refreshToken == "rt-T2")
        let o = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(((o["mcpOAuth"] as? [String: Any])?["linear"] as? [String: Any])?["accessToken"] as? String == "m1")
    }

    @Test func terminalInvalidGrantUsesTokenClaudeCodeJustRefreshed() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)])
        let replacement = try terminalBlob(.fake("byClaudeCode", expiresAt: future))
        let service = item.service, account = item.account
        http.onSend = { _ in try? secrets.write(service: service, account: account, data: replacement) }
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-byClaudeCode")
    }

    @Test func terminalExpiredInReadOnlyModeThrows() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let p = provider(http: FakeHTTPClient([]), secrets: secrets,
                         store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets), allowRefresh: false)
        await #expect(throws: RefreshError.refreshDisabled) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
    }

    @Test func appOwnedNearExpiryRefreshesAndSaves() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: Account.fake("B").id)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-B2","refresh_token":"rt-B2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: store)
        #expect(try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false) == "at-B2")
        #expect(try store.credentials(for: Account.fake("B").id)?.refreshToken == "rt-B2")
    }

    @Test func appOwnedForceRefreshEvenWhenFresh() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: future), for: Account.fake("B").id)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-B3","expires_in":28800}"#)])
        #expect(try await provider(http: http, secrets: secrets, store: store)
            .accessToken(for: .fake("B"), isTerminal: false, forceRefresh: true) == "at-B3")
    }

    @Test func missingAppCredentials() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let p = provider(http: FakeHTTPClient([]), secrets: secrets,
                         store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        await #expect(throws: RefreshError.missingCredentials) {
            _ = try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false)
        }
    }
}

/// Fails the first `failures` writes, then delegates.
final class FlakyWriteStore: SecretStore, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    let inner: InMemorySecretStore
    private var remaining: Int
    init(_ inner: InMemorySecretStore, failures: Int) { self.inner = inner; remaining = failures }
    func read(service: String, account: String) throws -> Data? { try inner.read(service: service, account: account) }
    func write(service: String, account: String, data: Data) throws {
        let fail = lock.locked { () -> Bool in if remaining > 0 { remaining -= 1; return true }; return false }
        if fail { throw Boom() }
        try inner.write(service: service, account: account, data: data)
    }
    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

/// After the first read of an item, later reads return `replacement` (simulates Claude Code writing meanwhile).
final class ReadSwapStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    let inner: InMemorySecretStore
    let replacement: Data
    private var reads = 0
    init(_ inner: InMemorySecretStore, replacement: Data) { self.inner = inner; self.replacement = replacement }
    func read(service: String, account: String) throws -> Data? {
        let n = lock.locked { reads += 1; return reads }
        return n == 1 ? try inner.read(service: service, account: account) : replacement
    }
    func write(service: String, account: String, data: Data) throws { try inner.write(service: service, account: account, data: data) }
    func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
}

extension CredentialProviderTests {
    var graceExpired: Int64 { Int64((now.now().timeIntervalSince1970 - 60) * 1_000) }
    var tAccount: String { Account.fake("T").id }

    @Test func forcedInsideGraceDoesNotRefreshAndAwaitsClaudeCode() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: graceExpired)))
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        await #expect(throws: RefreshError.awaitingClaudeCode) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: true)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func forcedInsideGraceReturnsTokenClaudeCodeWroteMeanwhile() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        try inner.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: graceExpired)))
        let secrets = ReadSwapStore(inner, replacement: try terminalBlob(.fake("new", expiresAt: future)))
        let http = FakeHTTPClient([])
        let p = CredentialProvider(store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets), secrets: secrets,
                                   terminalItem: item, refresher: TokenRefresher(http: http, now: now), now: now)
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: true) == "at-new")
        #expect(http.requests.isEmpty)
    }

    @Test func forcedWellPastGraceRefreshes() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account,
                          data: terminalBlob(.fake("T", expiresAt: Int64((now.now().timeIntervalSince1970 - 360) * 1_000))))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: true) == "at-T2")
    }

    @Test func forcedWithValidTerminalTokenMakesNoRequest() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: future)))
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: true) == "at-T")
        #expect(http.requests.isEmpty)
    }

    @Test func terminalWriteBackSkippedWhenItemHoldsAnotherAccount() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let other = try terminalBlob(.fake("B", expiresAt: future))
        let service = item.service, account = item.account
        http.onSend = { _ in try? secrets.write(service: service, account: account, data: other) }
        let p = provider(http: http, secrets: secrets, store: store)
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        #expect(try secrets.read(service: item.service, account: item.account) == other)
        #expect(try store.credentials(for: tAccount)?.refreshToken == "rt-T2")
    }

    @Test func terminalWriteBackSkippedWhenItemDeleted() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let service = item.service, account = item.account
        http.onSend = { _ in try? secrets.delete(service: service, account: account) }
        let p = provider(http: http, secrets: secrets, store: store)
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        #expect(try secrets.read(service: item.service, account: item.account) == nil)
        #expect(try store.credentials(for: tAccount)?.refreshToken == "rt-T2")
    }

    @Test func terminalPersistRetriesOnceAfterWriteFailure() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let secrets = FlakyWriteStore(inner, failures: 1)
        try inner.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = CredentialProvider(store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets), secrets: secrets,
                                   terminalItem: item, refresher: TokenRefresher(http: http, now: now), now: now)
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        let raw = try #require(try inner.read(service: item.service, account: item.account))
        #expect(try CredentialsJSON.claudeAiOauth(from: raw)?.refreshToken == "rt-T2")
    }

    @Test func terminalPersistFailingTwiceKeepsTheRotatedTokenInTheAppStore() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let blob = try terminalBlob(.fake("T", expiresAt: longExpired))
        try inner.write(service: item.service, account: item.account, data: blob)
        let secrets = FlakyWriteStore(inner, failures: 2)
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = CredentialProvider(store: store, secrets: secrets, terminalItem: item,
                                   refresher: TokenRefresher(http: http, now: now), now: now)
        await #expect(throws: FlakyWriteStore.Boom.self) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
        #expect(try store.credentials(for: tAccount)?.refreshToken == "rt-T2")
        #expect(try inner.read(service: item.service, account: item.account) == blob)
    }

    @Test func terminalWriteBackKeepsClaudeAiOauthKeysItDoesNotModel() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"at-T","refreshToken":"rt-T","expiresAt":\#(longExpired),"scopes":["user:inference"],"future":{"x":1}},"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8)
        try secrets.write(service: item.service, account: item.account, data: blob)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        let raw = try #require(try secrets.read(service: item.service, account: item.account))
        let o = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let oauth = try #require(o["claudeAiOauth"] as? [String: Any])
        #expect(oauth["future"] as? NSDictionary == ["x": 1])
        #expect(oauth["refreshToken"] as? String == "rt-T2")
        #expect(((o["mcpOAuth"] as? [String: Any])?["linear"] as? [String: Any])?["accessToken"] as? String == "m1")
    }

    @Test func appPersistRetriesOnceAfterWriteFailure() async throws {
        let dir = try TempDir()
        let inner = InMemorySecretStore()
        let secrets = FlakyWriteStore(inner, failures: 0)
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: Account.fake("B").id)
        let flaky = FlakyWriteStore(inner, failures: 1)
        let flakyStore = AccountStore(fileURL: dir.file("a.json"), secrets: flaky)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-B2","refresh_token":"rt-B2","expires_in":28800}"#)])
        let p = CredentialProvider(store: flakyStore, secrets: flaky, terminalItem: item,
                                   refresher: TokenRefresher(http: http, now: now), now: now)
        #expect(try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false) == "at-B2")
        #expect(try store.credentials(for: Account.fake("B").id)?.refreshToken == "rt-B2")
    }

    @Test func terminalInvalidGrantWithUnchangedItemThrowsAndWritesNothing() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let blob = try terminalBlob(.fake("T", expiresAt: longExpired))
        try secrets.write(service: item.service, account: item.account, data: blob)
        let http = FakeHTTPClient([FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        await #expect(throws: RefreshError.invalidGrant) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
        #expect(try secrets.read(service: item.service, account: item.account) == blob)
        #expect(secrets.allKeys == [InMemorySecretStore.key(service: item.service, account: item.account)])
    }

    @Test func terminalReadOnlyLeavesItemUntouched() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let blob = try terminalBlob(.fake("T", expiresAt: longExpired))
        try secrets.write(service: item.service, account: item.account, data: blob)
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets),
                         allowRefresh: false)
        await #expect(throws: RefreshError.refreshDisabled) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
        #expect(try secrets.read(service: item.service, account: item.account) == blob)
        #expect(http.requests.isEmpty)
    }

    @Test func missingTerminalItem() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let p = provider(http: FakeHTTPClient([]), secrets: secrets,
                         store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        await #expect(throws: RefreshError.missingCredentials) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
    }

    @Test func appOwnedReadOnlyMode() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: store, allowRefresh: false)
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: Account.fake("B").id)
        #expect(try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false) == "at-B")
        try store.setCredentials(.fake("B", expiresAt: longExpired), for: Account.fake("B").id)
        await #expect(throws: RefreshError.refreshDisabled) {
            _ = try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func appOwnedInvalidGrantAdoptsTokenRefreshedElsewhere() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        let id = Account.fake("B").id
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: id)
        let http = FakeHTTPClient([FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)])
        let newer = OAuthCredentials.fake("B2", expiresAt: future)
        http.onSend = { _ in try? store.setCredentials(newer, for: id) }
        let p = provider(http: http, secrets: secrets, store: store)
        #expect(try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false) == "at-B2")
    }

    @Test func appOwnedInvalidGrantWithUnchangedStoreThrows() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: Account.fake("B").id)
        let http = FakeHTTPClient([FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)])
        let p = provider(http: http, secrets: secrets, store: store)
        await #expect(throws: RefreshError.invalidGrant) {
            _ = try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false)
        }
    }
}
