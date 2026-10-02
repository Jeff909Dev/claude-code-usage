import CryptoKit
import Foundation

public struct OAuthCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since 1970, as Claude Code stores it.
    public var expiresAt: Int64
    public var refreshTokenExpiresAt: Int64?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    /// The `claudeAiOauth` keys this app models; Claude Code may add others.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case accessToken, refreshToken, expiresAt, refreshTokenExpiresAt, scopes, subscriptionType, rateLimitTier
    }

    public init(accessToken: String, refreshToken: String, expiresAt: Int64, refreshTokenExpiresAt: Int64?,
                scopes: [String], subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var expiresAtDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

extension OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// No children, so `dump` and `String(reflecting:)` cannot expose the tokens.
    public var customMirror: Mirror { Mirror(self, children: []) }

    public var description: String {
        "OAuthCredentials(expiresAt: \(expiresAt), scopes: \(scopes.count), tokens: <redacted>)"
    }
    public var debugDescription: String { description }
}

public enum CredentialsJSONError: Error, Equatable {
    case notAnObject
    /// `claudeAiOauth` is present but is neither an object nor null.
    case invalidOAuthValue
}

/// Reads and writes the JSON blob Claude Code keeps in its Keychain item:
/// `{"claudeAiOauth": {...}, "mcpOAuth": {...}, ...}`.
public enum CredentialsJSON {
    public static let oauthKey = "claudeAiOauth"

    public static func claudeAiOauth(from raw: Data) throws -> OAuthCredentials? {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CredentialsJSONError.notAnObject
        }
        guard let inner = object[oauthKey], !(inner is NSNull) else { return nil }
        guard inner is [String: Any] else { throw CredentialsJSONError.invalidOAuthValue }
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        return try JSONDecoder().decode(OAuthCredentials.self, from: innerData)
    }

    /// What happens to the `claudeAiOauth` object already in the item.
    public enum Mode: Sendable {
        /// Another account's login: the old object goes, so none of its keys carry over to the new account.
        case replace
        /// The same account's renewed login: the modelled keys are written over the old object, keeping keys a newer
        /// Claude Code added that this app does not know.
        case overlay
    }

    /// Writes `creds` as `claudeAiOauth`; every other top-level key (e.g. `mcpOAuth`) is kept as is.
    public static func merging(_ creds: OAuthCredentials, into raw: Data?, mode: Mode = .replace) throws -> Data {
        var object: [String: Any] = [:]
        if let raw, !raw.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw CredentialsJSONError.notAnObject
            }
            object = existing
        }
        var oauth = try JSONSerialization.jsonObject(with: JSONEncoder().encode(creds))
        if mode == .overlay, var previous = object[oauthKey] as? [String: Any], let fresh = oauth as? [String: Any] {
            // A modelled key the new credentials leave out must not keep its old value.
            for key in OAuthCredentials.CodingKeys.allCases { previous[key.rawValue] = nil }
            oauth = previous.merging(fresh) { $1 }
        }
        object[oauthKey] = oauth
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data(asciiEscaped(String(decoding: json, as: UTF8.self)).utf8)
    }

    /// `security find-generic-password -w` prints hex instead of text when a value has non-ASCII bytes, so our own
    /// writes stay ASCII: non-ASCII scalars (only ever inside JSON strings) become `\uXXXX` escapes.
    private static func asciiEscaped(_ json: String) -> String {
        var out = ""
        for scalar in json.unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else {
                for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
            }
        }
        return out
    }
}

public enum ClaudeCodeKeychain {
    public static let baseService = "Claude Code-credentials"

    /// Claude Code suffixes the service with the first 8 hex chars of sha256(CLAUDE_CONFIG_DIR) when it is set.
    public static func serviceName(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return baseService }
        let hex = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }
}
