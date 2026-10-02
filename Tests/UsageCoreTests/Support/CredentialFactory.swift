@testable import UsageCore

extension OAuthCredentials {
    static func fake(_ tag: String,
                     expiresAt: Int64 = 1_790_907_890_004,
                     refreshTokenExpiresAt: Int64? = 1_792_663_758_004) -> OAuthCredentials {
        OAuthCredentials(accessToken: "at-\(tag)", refreshToken: "rt-\(tag)", expiresAt: expiresAt,
                         refreshTokenExpiresAt: refreshTokenExpiresAt,
                         scopes: ["user:inference", "user:profile"],
                         subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    }
}
