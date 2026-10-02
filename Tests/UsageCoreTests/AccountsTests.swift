import Foundation
import Testing
@testable import UsageCore

struct AccountsTests {
    @Test(arguments: [
        ("max", "default_claude_max_20x", "claude_max", "Max 20x"),
        ("max", "default_claude_max_5x", "claude_max", "Max 5x"),
        ("pro", "default_claude_ai", "claude_pro", "Pro"),
        (nil, "default_claude_ai", "claude_pro", "Pro"),
        ("team", "team_premium", "claude_team", "Team · Premium"),
        ("team", "team_standard", "claude_team", "Team"),
        ("enterprise", nil, "claude_enterprise", "Enterprise"),
        (nil, nil, nil, "Claude"),
    ] as [(String?, String?, String?, String)])
    func planNames(sub: String?, tier: String?, orgType: String?, expected: String) {
        #expect(PlanName.from(subscriptionType: sub, rateLimitTier: tier, organizationType: orgType) == expected)
    }

    @Test func defaultLabels() {
        #expect(Account.defaultLabel(email: "you@work.example", organizationName: "you@work.example's Organization") == "Work")
        #expect(Account.defaultLabel(email: "someone@gmail.example", organizationName: nil) == "someone")
        #expect(Account.defaultLabel(email: "a@b.com", organizationName: "Northwind Studio") == "Northwind Studio")
    }

    @Test func storeRoundTripsAndKeepsOrderOnUpsert() throws {
        let dir = try TempDir()
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        #expect(try store.load().isEmpty)
        try store.upsert(.fake("A"))
        try store.upsert(.fake("B"))
        var renamed = Account.fake("A")
        renamed.label = "Work"
        try store.upsert(renamed)
        #expect(try store.load().map(\.label) == ["Work", "B"])
        try store.update(id: "acc-B:org-B") { $0.status = .needsSignIn }
        #expect(try store.account(id: "acc-B:org-B")?.status == .needsSignIn)
    }

    @Test func credentialsLiveUnderClaudeUsageServiceAndAreRemovedWithTheAccount() throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: secrets)
        try store.upsert(.fake("A"))
        try store.setCredentials(.fake("A"), for: "acc-A:org-A")
        #expect(secrets.allKeys == ["Claude Usage|acc-A:org-A"])
        #expect(try store.credentials(for: "acc-A:org-A") == .fake("A"))
        try store.remove(id: "acc-A:org-A")
        #expect(secrets.allKeys.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func nextColorIndexPicksFirstUnused() throws {
        let dir = try TempDir()
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        var a = Account.fake("A"); a.colorIndex = 0
        var b = Account.fake("B"); b.colorIndex = 2
        try store.save([a, b])
        #expect(try store.nextColorIndex() == 1)
    }

    @Test func payloadFallsBackToSynthesizedOAuthAccount() throws {
        var a = Account.fake("A")
        a.oauthAccountJSON = nil
        let o = try #require(try JSONSerialization.jsonObject(with: a.oauthAccountPayload()) as? [String: Any])
        #expect(o["accountUuid"] as? String == "acc-A")
        #expect(o["organizationUuid"] as? String == "org-A")
        #expect(o["emailAddress"] as? String == "a@example.com")
        #expect(o["organizationRateLimitTier"] as? String == "default_claude_max_20x")
    }

    @Test func existingOrNewCoversBothBranches() throws {
        let dir = try TempDir()
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        var used = Account.fake("A"); used.colorIndex = 0
        try store.save([used])
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        let made = try store.existingOrNew(id: "acc-N:org-N", accountUuid: "acc-N", organizationUuid: "org-N",
                                           email: "n@acme.io", organizationName: "Acme Inc", now: now)
        #expect(made.organizationName == "Acme Inc")
        #expect(made.label == "Acme Inc")
        #expect(made.colorIndex == 1)
        #expect(made.addedAt == now)
        #expect(made.status == .ok)
        #expect(try store.load().count == 1)
        let found = try store.existingOrNew(id: used.id, accountUuid: "x", organizationUuid: "y", email: "z@z.z",
                                            organizationName: "Other", now: now)
        #expect(found == used)
    }
}
