import Foundation

public struct TerminalIdentity: Sendable, Equatable {
    public var accountUuid: String
    public var organizationUuid: String
    public var email: String
    public var accountID: String { Account.makeID(accountUuid: accountUuid, organizationUuid: organizationUuid) }
}

public enum TerminalAccountError: Error, Equatable {
    case notAnObject
    case lockTimeout
    case lockFailed(Int32)
    case concurrentModification
    case renameFailed(Int32)
    case invalidReplacement
}

/// Claude Code's lock convention: a `<file>.lock` directory, considered stale after 10 s.
struct DirectoryLock {
    let url: URL
    var staleAfter: TimeInterval = 10

    func acquire(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if mkdir(url.path, 0o755) == 0 { return }
            let error = errno
            guard error == EEXIST else { throw TerminalAccountError.lockFailed(error) }
            if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > staleAfter {
                if rmdir(url.path) == 0 || errno == ENOENT { continue }
            }
            if Date() >= deadline { throw TerminalAccountError.lockTimeout }
            usleep(50_000)
        }
    }

    func release() { rmdir(url.path) }
}

/// `~/.claude.json` — which account the terminal uses (`oauthAccount`). Other keys are never touched.
public struct TerminalAccountFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// nil when the file does not exist, is not a JSON object, or has no `oauthAccount`; throws when unreadable or invalid.
    public func readOAuthAccountJSON() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let oauth = (object as? [String: Any])?["oauthAccount"] as? [String: Any] else { return nil }
        return try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys])
    }

    public func currentIdentity() throws -> TerminalIdentity? {
        try readOAuthAccountJSON().flatMap(Self.identity(fromOAuthAccountJSON:))
    }

    public static func identity(fromOAuthAccountJSON data: Data) -> TerminalIdentity? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = o["accountUuid"] as? String, let org = o["organizationUuid"] as? String else { return nil }
        return TerminalIdentity(accountUuid: account, organizationUuid: org, email: o["emailAddress"] as? String ?? "")
    }

    /// Read-modify-write under Claude Code's lock; retries when the file changed between our read and our rename.
    public func replaceOAuthAccount(with json: Data, maxAttempts: Int = 5, lockTimeout: TimeInterval = 3,
                                    beforeSwap: (() throws -> Void)? = nil) throws {
        guard Self.identity(fromOAuthAccountJSON: json) != nil else { throw TerminalAccountError.invalidReplacement }
        let replacement = try JSONSerialization.jsonObject(with: json)
        // Work on the real file when ~/.claude.json is a symlink, so the link itself is kept.
        let target = url.resolvingSymlinksInPath()
        let lock = DirectoryLock(url: URL(fileURLWithPath: target.path + ".lock"))
        for _ in 0..<maxAttempts {
            try lock.acquire(timeout: lockTimeout)
            defer { lock.release() }

            let original = try Data(contentsOf: target)
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw TerminalAccountError.notAnObject
            }
            object["oauthAccount"] = replacement
            let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])

            // The file can hold secrets: create the copy with the original's mode from the start.
            let mode = (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0o600
            let temp = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).claude-usage-\(UUID().uuidString)")
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode & 0o7777))
            guard fd >= 0 else { throw TerminalAccountError.renameFailed(errno) }
            defer { unlink(temp.path) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: output)
            try handle.synchronize()
            try handle.close()

            try beforeSwap?()
            guard try Data(contentsOf: target) == original else { continue }
            guard rename(temp.path, target.path) == 0 else { throw TerminalAccountError.renameFailed(errno) }
            return
        }
        throw TerminalAccountError.concurrentModification
    }
}

public enum TerminalAccountImporter {
    /// Makes sure the terminal's current account is listed and up to date. Its credentials stay owned by Claude Code.
    /// Runs every poll, so accounts.json is only written when something changed.
    @discardableResult
    public static func importIfNeeded(store: AccountStore, terminal: TerminalAccountFile, now: Date) throws -> Account? {
        guard let json = try terminal.readOAuthAccountJSON(),
              let identity = TerminalAccountFile.identity(fromOAuthAccountJSON: json),
              let o = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let organizationName = o["organizationName"] as? String
        let stored = try store.account(id: identity.accountID)
        var account = try stored ?? store.existingOrNew(
            id: identity.accountID, accountUuid: identity.accountUuid, organizationUuid: identity.organizationUuid,
            email: identity.email, organizationName: organizationName, now: now)
        account.email = identity.email
        account.displayName = o["displayName"] as? String ?? account.displayName
        account.organizationName = organizationName ?? account.organizationName
        account.organizationType = o["organizationType"] as? String ?? account.organizationType
        account.rateLimitTier = o["organizationRateLimitTier"] as? String ?? account.rateLimitTier
        account.oauthAccountJSON = json
        if account == stored { return account }
        return try store.upsert(account)
    }
}
