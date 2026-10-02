import Foundation
import Testing
@testable import UsageCore

struct CredentialsTests {
    static let claudeCodeItem = Data(#"""
    {"claudeAiOauth":{"accessToken":"at-A","refreshToken":"rt-A","expiresAt":1790907890004,"refreshTokenExpiresAt":1792663758004,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{"linear":{"accessToken":"m1"}}}
    """#.utf8)

    @Test func serviceNameFollowsClaudeCodeSha8Rule() {
        #expect(ClaudeCodeKeychain.serviceName(configDir: nil) == "Claude Code-credentials")
        #expect(ClaudeCodeKeychain.serviceName(configDir: "/Users/dev/.claude") == "Claude Code-credentials-c6b08108")
    }

    @Test func readsClaudeAiOauth() throws {
        let c = try #require(try CredentialsJSON.claudeAiOauth(from: Self.claudeCodeItem))
        #expect(c.accessToken == "at-A")
        #expect(c.expiresAt == 1_790_907_890_004)
        #expect(c.rateLimitTier == "default_claude_max_20x")
        #expect(c.expiresAtDate == Date(timeIntervalSince1970: 1_790_907_890.004))
    }

    @Test func missingClaudeAiOauthReturnsNil() throws {
        #expect(try CredentialsJSON.claudeAiOauth(from: Data(#"{"mcpOAuth":{}}"#.utf8)) == nil)
    }

    @Test func mergeReplacesOnlyClaudeAiOauthAndKeepsMcpOAuth() throws {
        let b = OAuthCredentials.fake("B")
        let merged = try CredentialsJSON.merging(b, into: Self.claudeCodeItem)
        let obj = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let mcp = try #require(obj["mcpOAuth"] as? [String: Any])
        #expect((mcp["linear"] as? [String: Any])?["accessToken"] as? String == "m1")
        #expect(try CredentialsJSON.claudeAiOauth(from: merged) == b)
    }

    static let itemWithUnmodelledKeys = Data(#"""
    {"claudeAiOauth":{"accessToken":"at-A","refreshToken":"rt-A","expiresAt":1,"refreshTokenExpiresAt":5,"scopes":[],"future":{"x":1}},"mcpOAuth":{"linear":{"accessToken":"m1"}}}
    """#.utf8)

    func parts(_ raw: Data) throws -> (oauth: [String: Any], mcp: NSDictionary?) {
        let obj = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return (try #require(obj["claudeAiOauth"] as? [String: Any]), obj["mcpOAuth"] as? NSDictionary)
    }

    @Test func overlayKeepsUnmodelledOAuthKeysAndMcpOAuth() throws {
        var fresh = OAuthCredentials.fake("A2")
        fresh.refreshTokenExpiresAt = nil
        let merged = try CredentialsJSON.merging(fresh, into: Self.itemWithUnmodelledKeys, mode: .overlay)
        #expect(try CredentialsJSON.claudeAiOauth(from: merged) == fresh)
        let (oauth, mcp) = try parts(merged)
        #expect(oauth["future"] as? NSDictionary == ["x": 1])
        #expect(oauth["refreshTokenExpiresAt"] == nil, "a modelled key the new login lacks must not stay stale")
        #expect(mcp == ["linear": ["accessToken": "m1"]])
    }

    @Test func replaceDropsThePreviousLoginsOAuthKeysButKeepsMcpOAuth() throws {
        let merged = try CredentialsJSON.merging(.fake("B"), into: Self.itemWithUnmodelledKeys, mode: .replace)
        #expect(try CredentialsJSON.claudeAiOauth(from: merged) == .fake("B"))
        let (oauth, mcp) = try parts(merged)
        #expect(oauth["future"] == nil)
        #expect(mcp == ["linear": ["accessToken": "m1"]])
    }

    @Test func overlayOntoNoOrNullOAuthWritesJustTheCredentials() throws {
        for raw in [nil, Data(#"{"claudeAiOauth":null,"mcpOAuth":{}}"#.utf8)] {
            let merged = try CredentialsJSON.merging(.fake("B"), into: raw, mode: .overlay)
            #expect(try CredentialsJSON.claudeAiOauth(from: merged) == .fake("B"))
            #expect(Set(try parts(merged).oauth.keys) == Set(try parts(CredentialsJSON.merging(.fake("B"), into: nil)).oauth.keys))
        }
    }

    @Test func mergeIntoNothingCreatesObject() throws {
        let b = OAuthCredentials.fake("B")
        #expect(try CredentialsJSON.claudeAiOauth(from: CredentialsJSON.merging(b, into: nil)) == b)
    }

    @Test func descriptionNeverContainsTokens() {
        let c = OAuthCredentials.fake("secret")
        #expect(!String(describing: c).contains("at-secret"))
        #expect(!"\(c)".contains("rt-secret"))
    }

    @Test func emptyConfigDirBehavesLikeNil() {
        #expect(ClaudeCodeKeychain.serviceName(configDir: "") == "Claude Code-credentials")
    }

    @Test func nullClaudeAiOauthIsNoCredentials() throws {
        #expect(try CredentialsJSON.claudeAiOauth(from: Data(#"{"claudeAiOauth":null}"#.utf8)) == nil)
    }

    @Test func nonObjectClaudeAiOauthThrowsTypedError() {
        #expect(throws: CredentialsJSONError.invalidOAuthValue) {
            try CredentialsJSON.claudeAiOauth(from: Data(#"{"claudeAiOauth":"oops"}"#.utf8))
        }
        #expect(throws: CredentialsJSONError.invalidOAuthValue) {
            try CredentialsJSON.claudeAiOauth(from: Data(#"{"claudeAiOauth":12}"#.utf8))
        }
    }

    @Test func reflectionNeverExposesTokens() {
        let c = OAuthCredentials.fake("secret")
        var dumped = ""
        dump(c, to: &dumped)
        #expect(!dumped.contains("at-secret") && !dumped.contains("rt-secret"))
        let reflected = String(reflecting: c)
        #expect(!reflected.contains("at-secret") && !reflected.contains("rt-secret"))
    }

    @Test func mergePreservesNumbersBoolsNullsAndUnknownKeys() throws {
        let raw = Data(#"""
        {"top":[1,2],"flag":true,"nothing":null,"big":9223372036854775807,"mcpOAuth":{"a":{"n":1790907890004,"b":false,"z":null,"u":"é","x":{"k":[]}}}}
        """#.utf8)
        let merged = try CredentialsJSON.merging(.fake("B"), into: raw)
        let text = String(decoding: merged, as: UTF8.self)
        #expect(text.contains("9223372036854775807"))
        #expect(text.contains("1790907890004"))
        #expect(text.contains(#""b":false"#))
        #expect(text.contains(#""z":null"#))
        #expect(text.contains(#""flag":true"#))
        #expect(text.contains(#""nothing":null"#))
        #expect(text.contains(#""top":[1,2]"#))
        #expect(text.contains(#""x":{"k":[]}"#))
        #expect(merged.allSatisfy { $0 < 0x80 })
        let obj = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let a = try #require((obj["mcpOAuth"] as? [String: Any])?["a"] as? [String: Any])
        #expect(a["u"] as? String == "é")
    }

    @Test func mergeEscapesNonBmpAsSurrogatePairs() throws {
        var c = OAuthCredentials.fake("B")
        c.subscriptionType = "p\u{1F600}é"
        let merged = try CredentialsJSON.merging(c, into: nil)
        #expect(merged.allSatisfy { $0 < 0x80 })
        #expect(try CredentialsJSON.claudeAiOauth(from: merged) == c)
    }

    @Test func mergeIntoTopLevelArrayThrowsNotAnObject() {
        #expect(throws: CredentialsJSONError.notAnObject) {
            try CredentialsJSON.merging(.fake("B"), into: Data("[1]".utf8))
        }
    }

    @Test func mergeIntoInvalidJSONThrowsInsteadOfOverwriting() {
        #expect(throws: (any Error).self) {
            try CredentialsJSON.merging(.fake("B"), into: Data("{not json".utf8))
        }
    }
}
