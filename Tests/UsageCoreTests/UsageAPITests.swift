import Foundation
import Testing
@testable import UsageCore

struct ISODateTests {
    @Test func parsesMicrosecondsWithOffset() throws {
        let d = try #require(ISODate.parse("2026-10-01T22:30:00.474962+00:00"))
        #expect(abs(d.timeIntervalSince1970 - 1_790_893_800.474962) < 0.0005)
    }
    @Test func parsesMillisWithZ() throws {
        let d = try #require(ISODate.parse("2026-10-01T15:27:38.176Z"))
        #expect(abs(d.timeIntervalSince1970 - 1_790_868_458.176) < 0.0005)
    }
    @Test func parsesWithoutFraction() {
        #expect(ISODate.parse("2026-10-06T04:00:00Z") == Date(timeIntervalSince1970: 1_791_259_200))
    }
    @Test func rejectsGarbage() { #expect(ISODate.parse("tomorrow") == nil) }
}

struct UsageAPITests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_884_800))

    @Test func decodesLiveShapeInDisplayOrder() throws {
        let s = try UsageAPI.decodeUsage(Data(Fixtures.usageJSON.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(s.limits.map(\.title) == ["Session · 5h", "Week · all models", "Week · Fable"])
        #expect(s.limits.map(\.percent) == [25, 54, 64])
        #expect(s.limits.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(s.limits[0].windowSeconds == UsageLimit.sessionSeconds)
        #expect(s.limits[2].windowSeconds == UsageLimit.weekSeconds)
        #expect(s.limits[2].modelName == "Fable")
        #expect(s.limits[2].isActive)
        #expect(abs(s.limits[0].resetsAt!.timeIntervalSince1970 - 1_790_893_800.474962) < 0.001)
        #expect(s.surfaces.first == SurfaceShare(key: "claude_code", displayName: "Claude Code", percent: 100))
        #expect(s.extraUsageEnabled == false)
        #expect(s.session?.percent == 25)
        #expect(s.highestWeekly?.percent == 64)
        #expect(s.fetchedAt == now.now())
    }

    @Test func toleratesUnknownKindsBrokenEntriesAndStringSurfaces() throws {
        let json = #"""
        {"limits": [
          {"kind": 5},
          {"kind": "mystery_meter", "group": "daily", "percent": 10, "resets_at": null},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 30, "scope": {"model": null, "surface": "cowork"}}
        ]}
        """#
        let s = try UsageAPI.decodeUsage(Data(json.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.title) == ["Week · cowork", "Mystery meter"])
        #expect(s.limits[1].resetsAt == nil)
    }

    @Test func fallsBackToLegacyWindowsWithoutLimitsArray() throws {
        let json = #"{"five_hour": {"utilization": 12, "resets_at": "2026-10-01T22:30:00Z"}, "seven_day": {"utilization": 40, "resets_at": null}, "seven_day_opus": {"utilization": 70, "resets_at": null}}"#
        let s = try UsageAPI.decodeUsage(Data(json.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.title) == ["Session · 5h", "Week · all models", "Week · Opus"])
        #expect(s.limits.map(\.percent) == [12, 40, 70])
    }

    @Test func sendsBearerAndBetaHeaderToUsageEndpoint() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.usageJSON)])
        _ = try await UsageAPI(http: http, now: now).usage(accessToken: "tok")
        let r = try #require(http.requests.first)
        #expect(r.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func mapsHTTPErrors() async {
        func status(_ code: Int, headers: [String: String] = [:]) async -> UsageAPIError? {
            let http = FakeHTTPClient([FakeHTTPClient.json(code, "{}", headers: headers)])
            do { _ = try await UsageAPI(http: http, now: now).usage(accessToken: "t"); return nil }
            catch { return error as? UsageAPIError }
        }
        #expect(await status(401) == .unauthorized)
        #expect(await status(403) == .http(403))
        #expect(await status(429, headers: ["Retry-After": "120"]) == .rateLimited(retryAfter: 120))
        #expect(await status(500) == .http(500))
    }

    @Test func mapsTransportErrorsToNetwork() async {
        let http = FakeHTTPClient([])
        http.error = URLError(.notConnectedToInternet)
        await #expect(throws: UsageAPIError.network(String(URLError.notConnectedToInternet.rawValue))) {
            _ = try await UsageAPI(http: http, now: now).usage(accessToken: "t")
        }
    }

    @Test func decodesProfile() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.profileJSON())])
        let p = try await UsageAPI(http: http, now: now).profile(accessToken: "t")
        #expect(p.accountID == "acc-A:org-A")
        #expect(p.email == "you@work.example")
        #expect(p.organizationType == "claude_max")
        #expect(p.rateLimitTier == "default_claude_max_20x")
        #expect(p.hasClaudeMax)
        #expect(http.requests.first?.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
    }
}
