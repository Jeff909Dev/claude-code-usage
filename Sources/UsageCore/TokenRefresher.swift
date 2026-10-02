import Foundation

public enum OAuthEndpoint {
    public static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}

public enum RefreshError: Error, Equatable {
    case invalidGrant
    case http(Int)
    case network(String)
    case decoding
    case missingCredentials
    case refreshDisabled
    /// Claude Code owns this token and has not refreshed it yet; the app must not.
    case awaitingClaudeCode
}

public enum TokenOwner: Sendable, Equatable {
    case claudeCode, app
}

public enum RefreshPolicy {
    /// App-owned tokens are refreshed ahead of expiry.
    public static let appLeadTime: TimeInterval = 10 * 60
    /// Claude Code refreshes its own token while in use; only step in when it is clearly idle.
    public static let claudeCodeGrace: TimeInterval = 5 * 60

    public static func shouldRefresh(_ creds: OAuthCredentials, owner: TokenOwner, now: Date) -> Bool {
        switch owner {
        case .app: return creds.expiresAtDate.timeIntervalSince(now) < appLeadTime
        case .claudeCode: return now.timeIntervalSince(creds.expiresAtDate) > claudeCodeGrace
        }
    }
}

public struct TokenRefresher: Sendable {
    let http: any HTTPClient
    let now: any DateProvider

    static let defaultLifetime: TimeInterval = 3_600
    /// Longer lifetimes are not believed; the cap also keeps the millisecond timestamps far inside Int64.
    static let maxLifetime: TimeInterval = 315_360_000   // 10 years
    /// Words in a 400/401 body that mean "try again later" rather than "this login is gone".
    static let transientErrors = ["temporarily_unavailable", "server_error", "overloaded", "rate_limit"]

    public init(http: any HTTPClient, now: any DateProvider) {
        self.http = http
        self.now = now
    }

    public func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        var request = URLRequest(url: OAuthEndpoint.token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": OAuthEndpoint.clientID,
        ])
        request.timeoutInterval = 20

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await http.send(request) }
        catch let error as URLError { throw RefreshError.network(String(error.code.rawValue)) }

        guard (200..<300).contains(response.statusCode) else {
            // The token endpoint rejects a dead refresh token with 400/401, not always saying `invalid_grant`.
            if (400...401).contains(response.statusCode) {
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("invalid_grant") || !Self.transientErrors.contains(where: text.contains) {
                    throw RefreshError.invalidGrant
                }
            }
            throw RefreshError.http(response.statusCode)
        }
        // Lenient on purpose: the refresh token may have rotated, so only a missing access token is fatal.
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = body["access_token"] as? String, !accessToken.isEmpty else { throw RefreshError.decoding }

        func seconds(_ key: String) -> Double? {
            guard let value = (body[key] as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return min(value, Self.maxLifetime)
        }
        let issued = now.now().timeIntervalSince1970
        var fresh = creds
        fresh.accessToken = accessToken
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty { fresh.refreshToken = rotated }
        fresh.expiresAt = Int64(((issued + (seconds("expires_in") ?? Self.defaultLifetime)) * 1_000).rounded())
        if let lifetime = seconds("refresh_token_expires_in") {
            fresh.refreshTokenExpiresAt = Int64(((issued + lifetime) * 1_000).rounded())
        }
        if let scope = body["scope"] as? String { fresh.scopes = scope.split(separator: " ").map(String.init) }
        return fresh
    }
}
