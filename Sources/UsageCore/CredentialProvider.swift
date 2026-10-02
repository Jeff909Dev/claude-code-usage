import Foundation

public struct TerminalKeychainItem: Sendable, Equatable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static func live() -> TerminalKeychainItem {
        TerminalKeychainItem(service: ClaudeCodeKeychain.baseService, account: NSUserName())
    }
}

public protocol CredentialProviding: Sendable {
    func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String
}

/// Hands out access tokens while respecting who owns each refresh token (spec §6).
public struct CredentialProvider: CredentialProviding {
    let store: AccountStore
    let secrets: any SecretStore
    let terminalItem: TerminalKeychainItem
    let refresher: TokenRefresher
    let now: any DateProvider
    let allowRefresh: Bool

    public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem,
                refresher: TokenRefresher, now: any DateProvider, allowRefresh: Bool = true) {
        self.store = store
        self.secrets = secrets
        self.terminalItem = terminalItem
        self.refresher = refresher
        self.now = now
        self.allowRefresh = allowRefresh
    }

    public func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String {
        isTerminal ? try await terminalToken(for: account, forceRefresh: forceRefresh)
                   : try await appToken(for: account, forceRefresh: forceRefresh)
    }

    private func readTerminal() throws -> OAuthCredentials? {
        guard let raw = try secrets.read(service: terminalItem.service, account: terminalItem.account) else { return nil }
        return try CredentialsJSON.claudeAiOauth(from: raw)
    }

    /// A rotated refresh token must never be lost, so a failed persist is retried once.
    private func persistingTwice(_ body: () throws -> Void) throws {
        do { try body() } catch { try body() }
    }

    private func terminalToken(for account: Account, forceRefresh: Bool) async throws -> String {
        guard let creds = try readTerminal() else { throw RefreshError.missingCredentials }
        let current = now.now()
        guard RefreshPolicy.shouldRefresh(creds, owner: .claudeCode, now: current) else {
            // Claude Code owns this token. Even when forced, never refresh it inside the grace window.
            guard forceRefresh else { return creds.accessToken }
            if let again = try readTerminal(), again.accessToken != creds.accessToken { return again.accessToken }
            if creds.expiresAtDate <= current { throw RefreshError.awaitingClaudeCode }
            return creds.accessToken
        }
        guard allowRefresh else { throw RefreshError.refreshDisabled }
        do {
            let fresh = try await refresher.refresh(creds)
            do {
                try persistingTwice { try writeBackTerminal(fresh, replacing: creds.refreshToken, account: account) }
            } catch {
                // The server has already rotated the refresh token: keep it in the app's store rather than lose it.
                try? store.setCredentials(fresh, for: account.id)
                throw error
            }
            return fresh.accessToken
        } catch RefreshError.invalidGrant {
            // Claude Code may have rotated the token while we were refreshing.
            if let again = try readTerminal(), again.refreshToken != creds.refreshToken, again.expiresAtDate > now.now() {
                return again.accessToken
            }
            throw RefreshError.invalidGrant
        }
    }

    /// Compare-and-swap: only touch Claude Code's item if it still holds the refresh token we used. Otherwise the
    /// item now belongs to someone else (another login, deleted), so keep the fresh credentials in the app's store.
    private func writeBackTerminal(_ fresh: OAuthCredentials, replacing usedRefreshToken: String,
                                   account: Account) throws {
        let latest = try secrets.read(service: terminalItem.service, account: terminalItem.account)
        if let latest, let held = try? CredentialsJSON.claudeAiOauth(from: latest), held.refreshToken == usedRefreshToken {
            try secrets.write(service: terminalItem.service, account: terminalItem.account,
                              data: CredentialsJSON.merging(fresh, into: latest, mode: .overlay))
        } else {
            try store.setCredentials(fresh, for: account.id)
        }
    }

    private func appToken(for account: Account, forceRefresh: Bool) async throws -> String {
        guard let creds = try store.credentials(for: account.id) else { throw RefreshError.missingCredentials }
        guard forceRefresh || RefreshPolicy.shouldRefresh(creds, owner: .app, now: now.now()) else {
            return creds.accessToken
        }
        guard allowRefresh else {
            if creds.expiresAtDate > now.now() { return creds.accessToken }
            throw RefreshError.refreshDisabled
        }
        do {
            let fresh = try await refresher.refresh(creds)
            try persistingTwice { try store.setCredentials(fresh, for: account.id) }
            return fresh.accessToken
        } catch RefreshError.invalidGrant {
            // Another process may have refreshed (and rotated) this account's token meanwhile.
            if let again = try store.credentials(for: account.id), again.refreshToken != creds.refreshToken {
                return again.accessToken
            }
            throw RefreshError.invalidGrant
        }
    }
}
