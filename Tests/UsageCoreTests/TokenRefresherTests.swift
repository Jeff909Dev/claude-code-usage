import Foundation
import Testing
@testable import UsageCore

struct TokenRefresherTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))

    @Test func postsRefreshGrantAndBuildsNewCredentials() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"scope":"user:inference user:profile"}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.accessToken == "at-new")
        #expect(fresh.refreshToken == "rt-new")
        #expect(fresh.expiresAt == (1_790_870_400 + 28_800) * 1_000)
        #expect(fresh.scopes == ["user:inference", "user:profile"])
        #expect(fresh.subscriptionType == "max")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["grant_type": "refresh_token", "refresh_token": "rt-old",
                         "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
    }

    @Test func keepsOldRefreshTokenAndScopesWhenAbsent() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","expires_in":3600}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.refreshToken == "rt-old")
        #expect(fresh.scopes == OAuthCredentials.fake("old").scopes)
    }

    @Test func mapsErrors() async {
        func run(_ stub: FakeHTTPClient.Stub) async -> RefreshError? {
            do { _ = try await TokenRefresher(http: FakeHTTPClient([stub]), now: now).refresh(.fake("x")); return nil }
            catch { return error as? RefreshError }
        }
        #expect(await run(FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)) == .invalidGrant)
        #expect(await run(FakeHTTPClient.json(401, #"{"error":"invalid_grant","error_description":"revoked"}"#)) == .invalidGrant)
        #expect(await run(FakeHTTPClient.json(500, "{}")) == .http(500))
        #expect(await run(FakeHTTPClient.json(200, "not json")) == .decoding)
    }

    /// A 400/401 from the token endpoint means the refresh token is no good, unless the body calls it transient.
    @Test(arguments: [
        (400, #"{"error":"invalid_request"}"#, RefreshError.invalidGrant),
        (401, "{}", .invalidGrant),
        (400, "", .invalidGrant),
        (401, #"{"error":"unauthorized_client"}"#, .invalidGrant),
        (400, #"{"error":"temporarily_unavailable"}"#, .http(400)),
        (401, #"{"error":"server_error"}"#, .http(401)),
        (400, #"{"type":"error","error":{"type":"overloaded_error"}}"#, .http(400)),
        (400, #"{"type":"error","error":{"type":"rate_limit_error"}}"#, .http(400)),
        (403, "{}", .http(403)),
    ])
    func rejectedRefreshWithoutInvalidGrant(status: Int, body: String, expected: RefreshError) async {
        do {
            _ = try await TokenRefresher(http: FakeHTTPClient([FakeHTTPClient.json(status, body)]), now: now)
                .refresh(.fake("x"))
            Issue.record("expected \(expected)")
        } catch {
            #expect(error as? RefreshError == expected)
        }
    }

    @Test func mapsTransportFailureToNetworkWithoutDetails() async {
        let http = FakeHTTPClient([])
        http.error = URLError(.notConnectedToInternet)
        await #expect(throws: RefreshError.network(String(URLError.notConnectedToInternet.rawValue))) {
            _ = try await TokenRefresher(http: http, now: now).refresh(.fake("x"))
        }
    }

    @Test(arguments: [
        (TokenOwner.app, 5 * 60.0, true), (TokenOwner.app, 30 * 60.0, false),
        (TokenOwner.claudeCode, -60.0, false), (TokenOwner.claudeCode, -6 * 60.0, true),
        (TokenOwner.claudeCode, 60.0, false),
    ])
    func refreshPolicy(owner: TokenOwner, secondsUntilExpiry: Double, expected: Bool) {
        let expires = Int64((now.now().timeIntervalSince1970 + secondsUntilExpiry) * 1_000)
        #expect(RefreshPolicy.shouldRefresh(.fake("x", expiresAt: expires), owner: owner, now: now.now()) == expected)
    }
}

extension TokenRefresherTests {
    @Test func missingExpiresInDefaultsToOneHourAndKeepsRotatedRefreshToken() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","refresh_token":"rt-rot"}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.refreshToken == "rt-rot")
        #expect(fresh.expiresAt == (1_790_870_400 + 3_600) * 1_000)
    }

    @Test func oddExpiresInDefaultsToOneHour() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","expires_in":"soon"}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.expiresAt == (1_790_870_400 + 3_600) * 1_000)
    }

    @Test func refreshTokenExpiresInIsDecoded() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"a","expires_in":60,"refresh_token_expires_in":86400}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.refreshTokenExpiresAt == Int64((1_790_870_400 + 86_400) * 1_000))
    }

    /// nil: not a usable lifetime, so the access token gets the default hour and the refresh expiry is kept.
    @Test(arguments: [("1e19", 315_360_000), ("315360001", 315_360_000), ("28800", 28_800),
                      ("0", nil), ("-5", nil), (#""soon""#, nil)] as [(String, Double?)])
    func lifetimesAreCappedAtTenYears(raw: String, seconds: Double?) async throws {
        let body = #"{"access_token":"a","expires_in":\#(raw),"refresh_token_expires_in":\#(raw)}"#
        let fresh = try await TokenRefresher(http: FakeHTTPClient([FakeHTTPClient.json(200, body)]), now: now)
            .refresh(.fake("old"))
        let issued: Double = 1_790_870_400
        #expect(fresh.expiresAt == Int64((issued + (seconds ?? 3_600)) * 1_000))
        #expect(fresh.refreshTokenExpiresAt
                == seconds.map { Int64((issued + $0) * 1_000) } ?? OAuthCredentials.fake("old").refreshTokenExpiresAt)
    }

    @Test func missingAccessTokenIsDecodingError() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"expires_in":60}"#)])
        await #expect(throws: RefreshError.decoding) {
            _ = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        }
    }

    @Test func policyBoundariesAreExclusive() {
        func expiring(in s: Double) -> OAuthCredentials {
            .fake("x", expiresAt: Int64((now.now().timeIntervalSince1970 + s) * 1_000))
        }
        #expect(!RefreshPolicy.shouldRefresh(expiring(in: 600), owner: .app, now: now.now()))
        #expect(RefreshPolicy.shouldRefresh(expiring(in: 599), owner: .app, now: now.now()))
        #expect(!RefreshPolicy.shouldRefresh(expiring(in: -300), owner: .claudeCode, now: now.now()))
        #expect(RefreshPolicy.shouldRefresh(expiring(in: -301), owner: .claudeCode, now: now.now()))
    }
}
