import Foundation

public enum SwitchError: Error, Equatable {
    case unknownAccount, missingCredentials, alreadyActive, needsSignIn
    /// The default Keychain item holds another listed account's token, so it is not the terminal account's to save.
    case inconsistentTerminal
    /// The default item holds a login but ~/.claude.json says nobody is signed in; switching would drop that token.
    case unknownTerminalOwner
    /// Claude Code kept changing the default item while we were switching.
    case terminalChanging
    /// The switch failed and restoring Claude Code's previous Keychain item failed too. Carries no secrets.
    case rollbackFailed(underlying: String)
}

public struct SwitchResult: Sendable, Equatable {
    public var fromID: String?
    public var toID: String
}

/// "Use in terminal" (spec §6): points Claude Code's default Keychain item and ~/.claude.json at another account.
public struct AccountSwitcher: Sendable {
    let store: AccountStore
    let secrets: any SecretStore
    let terminalItem: TerminalKeychainItem
    let terminalFile: TerminalAccountFile
    let now: any DateProvider

    public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem,
                terminalFile: TerminalAccountFile, now: any DateProvider) {
        self.store = store
        self.secrets = secrets
        self.terminalItem = terminalItem
        self.terminalFile = terminalFile
        self.now = now
    }

    @discardableResult
    public func switchTerminal(to targetID: String) throws -> SwitchResult {
        guard let target = try store.account(id: targetID) else { throw SwitchError.unknownAccount }
        if try terminalFile.currentIdentity()?.accountID == targetID { throw SwitchError.alreadyActive }
        guard target.status != .needsSignIn else { throw SwitchError.needsSignIn }
        guard let targetCreds = try store.credentials(for: targetID) else { throw SwitchError.missingCredentials }
        if let refreshExpiry = targetCreds.refreshTokenExpiresAt,
           refreshExpiry <= Int64(now.now().timeIntervalSince1970 * 1000) {
            throw SwitchError.needsSignIn
        }

        // Fail before touching anything when the payload cannot be written for exactly this account.
        let payload = try target.oauthAccountPayload()
        guard TerminalAccountFile.identity(fromOAuthAccountJSON: payload)?.accountID == targetID else {
            throw TerminalAccountError.invalidReplacement
        }

        for _ in 0..<3 {
            let identity = try terminalFile.currentIdentity()
            if identity?.accountID == targetID { throw SwitchError.alreadyActive }
            let originalItem = try secrets.read(service: terminalItem.service, account: terminalItem.account)
            let outgoing = try originalItem.flatMap(CredentialsJSON.claudeAiOauth(from:))

            // 1. Keep the outgoing account: list it and keep its (possibly just refreshed) token as app-owned.
            //    The default item owns the current terminal account's token, so it wins over any app-owned copy.
            if let identity {
                if let outgoing { try requireOwnership(of: outgoing, by: identity.accountID) }
                try TerminalAccountImporter.importIfNeeded(store: store, terminal: terminalFile, now: now.now())
                if let outgoing { try store.setCredentials(outgoing, for: identity.accountID) }
            } else if outgoing != nil {
                throw SwitchError.unknownTerminalOwner
            }

            // Compare-and-swap: Claude Code may have rotated its token or MCP logins since we read the item.
            guard try secrets.read(service: terminalItem.service, account: terminalItem.account) == originalItem else {
                continue
            }

            // 2. Hand Claude Code the target's token, keeping mcpOAuth and every other key (none of A's claudeAiOauth
            //    keys carry over to B). A failed write may still have stored it.
            let switched = try CredentialsJSON.merging(targetCreds, into: originalItem, mode: .replace)
            do {
                try secrets.write(service: terminalItem.service, account: terminalItem.account, data: switched)
            } catch {
                try undo(switched, restoring: originalItem)
                throw error
            }

            // 3. Point ~/.claude.json at the target (takes a file lock; call off the main actor). Undo step 2 if that fails.
            do {
                try terminalFile.replaceOAuthAccount(with: payload)
            } catch {
                try undo(switched, restoring: originalItem)
                throw error
            }
            return SwitchResult(fromID: identity?.accountID, toID: targetID)
        }
        throw SwitchError.terminalChanging
    }

    /// The default item must not hold a token we already know belongs to a different listed account.
    private func requireOwnership(of outgoing: OAuthCredentials, by accountID: String) throws {
        for other in try store.load() where other.id != accountID {
            if let theirs = try store.credentials(for: other.id), theirs.refreshToken == outgoing.refreshToken {
                throw SwitchError.inconsistentTerminal
            }
        }
    }

    /// Puts Claude Code's item back to its exact previous bytes, but only while it still holds what we wrote: any other
    /// value is Claude Code's (e.g. a token it just rotated) and is left alone. A half-switched item would later destroy
    /// a token, so a failed undo is retried once and then reported.
    private func undo(_ written: Data, restoring original: Data?) throws {
        func attempt() throws {
            guard try secrets.read(service: terminalItem.service, account: terminalItem.account) == written else { return }
            if let original {
                try secrets.write(service: terminalItem.service, account: terminalItem.account, data: original)
            } else {
                try secrets.delete(service: terminalItem.service, account: terminalItem.account)
            }
        }
        do { try attempt() } catch {
            do { try attempt() } catch { throw SwitchError.rollbackFailed(underlying: String(describing: error)) }
        }
    }
}
