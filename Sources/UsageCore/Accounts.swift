import Foundation

public enum AccountStatus: String, Codable, Sendable {
    case ok, needsSignIn, offline, rateLimited
    /// The terminal's token was rejected and Claude Code, which owns it, has not refreshed it yet (spec §6).
    case waitingForClaudeCode
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var accountUuid: String
    public var organizationUuid: String
    public var email: String
    public var displayName: String?
    public var organizationName: String?
    public var organizationType: String?
    public var rateLimitTier: String?
    public var subscriptionType: String?
    public var label: String
    public var colorIndex: Int
    public var addedAt: Date
    public var status: AccountStatus
    /// This account's raw `oauthAccount` object from a `.claude.json`, written back on "Use in terminal".
    public var oauthAccountJSON: Data?

    public var plan: String {
        PlanName.from(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier,
                      organizationType: organizationType)
    }

    public static func makeID(accountUuid: String, organizationUuid: String) -> String {
        "\(accountUuid):\(organizationUuid)"
    }

    static let publicMailDomains: Set<String> = ["gmail", "googlemail", "outlook", "hotmail", "live", "icloud", "me",
                                                 "yahoo", "proton", "protonmail", "aol"]

    /// Org name when it is a real name; else the email's company domain ("you@work.example" → "Work"); else the local part.
    public static func defaultLabel(email: String, organizationName: String?) -> String {
        if let org = organizationName, !org.isEmpty, !org.hasSuffix("'s Organization") { return org }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        let local = parts.first ?? email
        guard parts.count == 2, let domain = parts[1].split(separator: ".").first.map(String.init),
              !publicMailDomains.contains(domain.lowercased()) else { return local }
        return domain.prefix(1).uppercased() + domain.dropFirst()
    }

    public func oauthAccountPayload() throws -> Data {
        if let oauthAccountJSON { return oauthAccountJSON }
        var o: [String: Any] = ["accountUuid": accountUuid, "organizationUuid": organizationUuid, "emailAddress": email]
        if let displayName { o["displayName"] = displayName }
        if let organizationName { o["organizationName"] = organizationName }
        if let organizationType { o["organizationType"] = organizationType }
        if let rateLimitTier { o["organizationRateLimitTier"] = rateLimitTier }
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
}

public enum PlanName {
    public static func from(subscriptionType: String?, rateLimitTier: String?, organizationType: String?) -> String {
        let tier = (rateLimitTier ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        let kind = (subscriptionType ?? organizationType ?? "").lowercased()
        if kind.contains("max") { return "Max" }
        if kind.contains("pro") { return "Pro" }
        if kind.contains("team") { return tier.contains("premium") ? "Team · Premium" : "Team" }
        if kind.contains("enterprise") { return "Enterprise" }
        return "Claude"
    }
}

/// Account list in accounts.json; app-owned credentials in the Keychain (service "Claude Usage").
public final class AccountStore: @unchecked Sendable {
    public static let keychainService = "Claude Usage"
    public static let paletteSize = 6

    private let fileURL: URL
    private let secrets: any SecretStore
    private let lock = NSLock()

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public func load() throws -> [Account] { try lock.locked { try loadUnlocked() } }

    public func save(_ accounts: [Account]) throws { try lock.locked { try saveUnlocked(accounts) } }

    public func account(id: String) throws -> Account? { try load().first { $0.id == id } }

    @discardableResult
    public func upsert(_ account: Account) throws -> Account {
        try lock.locked {
            var all = try loadUnlocked()
            if let i = all.firstIndex(where: { $0.id == account.id }) { all[i] = account } else { all.append(account) }
            try saveUnlocked(all)
            return account
        }
    }

    public func update(id: String, _ mutate: (inout Account) -> Void) throws {
        try lock.locked {
            var all = try loadUnlocked()
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            mutate(&all[i])
            try saveUnlocked(all)
        }
    }

    public func remove(id: String) throws {
        try lock.locked {
            try saveUnlocked(try loadUnlocked().filter { $0.id != id })
        }
        try secrets.delete(service: Self.keychainService, account: id)
    }

    public func credentials(for id: String) throws -> OAuthCredentials? {
        guard let data = try secrets.read(service: Self.keychainService, account: id) else { return nil }
        return try JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    public func setCredentials(_ creds: OAuthCredentials, for id: String) throws {
        try secrets.write(service: Self.keychainService, account: id, data: JSONEncoder().encode(creds))
    }

    /// The stored account with this id, or a new one (not yet saved) with a default label and the next free color.
    public func existingOrNew(id: String, accountUuid: String, organizationUuid: String, email: String,
                              organizationName: String?, now: Date) throws -> Account {
        if let existing = try account(id: id) { return existing }
        return Account(id: id, accountUuid: accountUuid, organizationUuid: organizationUuid, email: email,
                       displayName: nil, organizationName: organizationName, organizationType: nil, rateLimitTier: nil,
                       subscriptionType: nil,
                       label: Account.defaultLabel(email: email, organizationName: organizationName),
                       colorIndex: try nextColorIndex(), addedAt: now, status: .ok, oauthAccountJSON: nil)
    }

    public func nextColorIndex() throws -> Int {
        let all = try load()
        let used = Set(all.map(\.colorIndex))
        return (0..<Self.paletteSize).first { !used.contains($0) } ?? all.count % Self.paletteSize
    }

    private func loadUnlocked() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Account].self, from: Data(contentsOf: fileURL))
    }

    private func saveUnlocked(_ accounts: [Account]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: fileURL, options: .atomic)
    }
}
