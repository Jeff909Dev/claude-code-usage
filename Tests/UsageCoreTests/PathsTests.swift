import Foundation
import Testing
@testable import UsageCore

struct PathsTests {
    @Test func derivesClaudeAndAppSupportLocations() {
        let p = Paths(home: URL(fileURLWithPath: "/Users/x"), appSupport: URL(fileURLWithPath: "/tmp/support"))
        #expect(p.claudeJSON.path == "/Users/x/.claude.json")
        #expect(p.claudeConfigDir.path == "/Users/x/.claude")
        #expect(p.projectsDir.path == "/Users/x/.claude/projects")
        #expect(p.accountsFile.path == "/tmp/support/accounts.json")
        #expect(p.indexDatabase.path == "/tmp/support/index.sqlite")
        #expect(p.pricingOverride.path == "/tmp/support/pricing.json")
        #expect(p.settingsFile.path == "/tmp/support/settings.json")
        #expect(p.snapshotsCache.path == "/tmp/support/snapshots.json")
        #expect(p.notifierState.path == "/tmp/support/notifier.json")
        #expect(p.loginWorkRoot.path == "/tmp/support/login")
    }

    @Test func liveAppSupportIsNamedClaudeUsage() {
        #expect(Paths.live().appSupport.lastPathComponent == "ClaudeUsage")
    }

    @Test func fixedDateProviderReturnsItsDate() {
        let d = Date(timeIntervalSince1970: 1_000)
        #expect(FixedDateProvider(d).now() == d)
    }

    @Test func lockedReturnsBodyValue() {
        let lock = NSLock()
        #expect(lock.locked { 42 } == 42)
    }
}
