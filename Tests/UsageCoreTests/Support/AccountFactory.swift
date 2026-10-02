import Foundation
@testable import UsageCore

enum ClaudeJSONFixture {
    static func oauthAccount(tag: String, email: String) -> String {
        #"{"accountUuid":"acc-\#(tag)","organizationUuid":"org-\#(tag)","emailAddress":"\#(email)","displayName":"Jeff","organizationName":"\#(email)'s Organization","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","billingType":"stripe_subscription"}"#
    }

    static func file(tag: String, email: String) -> String {
        #"{"numStartups":7,"mcpServers":{"linear":{"type":"http"}},"oauthAccount":\#(oauthAccount(tag: tag, email: email))}"#
    }
}

extension Account {
    static func fake(_ tag: String, email: String? = nil, label: String? = nil, status: AccountStatus = .ok) -> Account {
        let mail = email ?? "\(tag.lowercased())@example.com"
        return Account(id: "acc-\(tag):org-\(tag)", accountUuid: "acc-\(tag)", organizationUuid: "org-\(tag)",
                       email: mail, displayName: "Jeff", organizationName: "\(mail)'s Organization",
                       organizationType: "claude_max", rateLimitTier: "default_claude_max_20x",
                       subscriptionType: "max", label: label ?? tag, colorIndex: 0,
                       addedAt: Date(timeIntervalSince1970: 1_790_000_000), status: status,
                       oauthAccountJSON: Data(ClaudeJSONFixture.oauthAccount(tag: tag, email: mail).utf8))
    }
}
