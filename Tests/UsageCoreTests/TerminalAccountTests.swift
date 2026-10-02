import Foundation
import Testing
@testable import UsageCore

struct TerminalAccountTests {
    let dir: TempDir
    let file: TerminalAccountFile

    init() throws {
        dir = try TempDir()
        try Data(ClaudeJSONFixture.file(tag: "A", email: "you@work.example").utf8).write(to: dir.file(".claude.json"))
        file = TerminalAccountFile(url: dir.file(".claude.json"))
    }

    func object() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.file(".claude.json"))) as? [String: Any])
    }

    @Test func readsIdentity() throws {
        #expect(try file.currentIdentity() == TerminalIdentity(accountUuid: "acc-A", organizationUuid: "org-A",
                                                                email: "you@work.example"))
        #expect(try file.currentIdentity()?.accountID == "acc-A:org-A")
    }

    @Test func missingOrInvalidFileHasNoIdentity() throws {
        #expect(try TerminalAccountFile(url: dir.file("nope.json")).currentIdentity() == nil)
        try Data("[]".utf8).write(to: dir.file("array.json"))
        #expect(try TerminalAccountFile(url: dir.file("array.json")).currentIdentity() == nil)
    }

    @Test func replaceKeepsEveryOtherKey() throws {
        try file.replaceOAuthAccount(with: Data(ClaudeJSONFixture.oauthAccount(tag: "B", email: "b@example.com").utf8))
        let o = try object()
        #expect(o["numStartups"] as? Int == 7)
        #expect((o["mcpServers"] as? [String: Any])?["linear"] != nil)
        #expect(try file.currentIdentity()?.email == "b@example.com")
        #expect(!FileManager.default.fileExists(atPath: dir.file(".claude.json.lock").path))
    }

    @Test func replaceRetriesWhenFileChangesUnderneath() throws {
        var interfered = false
        try file.replaceOAuthAccount(with: Data(ClaudeJSONFixture.oauthAccount(tag: "B", email: "b@example.com").utf8)) {
            guard !interfered else { return }
            interfered = true
            // A running `claude` rewrites the file between our read and our rename.
            try Data(#"{"numStartups":8,"oauthAccount":\#(ClaudeJSONFixture.oauthAccount(tag: "A", email: "you@work.example"))}"#.utf8)
                .write(to: dir.file(".claude.json"))
        }
        let o = try object()
        #expect(o["numStartups"] as? Int == 8)
        #expect(try file.currentIdentity()?.email == "b@example.com")
    }

    @Test func staleLockIsBroken() throws {
        let lock = dir.file(".claude.json.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock.path)
        try file.replaceOAuthAccount(with: Data(ClaudeJSONFixture.oauthAccount(tag: "B", email: "b@example.com").utf8))
        #expect(try file.currentIdentity()?.email == "b@example.com")
    }

    @Test func freshLockTimesOut() throws {
        let before = try Data(contentsOf: dir.file(".claude.json"))
        try FileManager.default.createDirectory(at: dir.file(".claude.json.lock"), withIntermediateDirectories: false)
        #expect(throws: TerminalAccountError.lockTimeout) {
            try file.replaceOAuthAccount(with: Data(ClaudeJSONFixture.oauthAccount(tag: "B", email: "b@example.com").utf8),
                                         lockTimeout: 0.2)
        }
        #expect(FileManager.default.fileExists(atPath: dir.file(".claude.json.lock").path))
        #expect(try Data(contentsOf: dir.file(".claude.json")) == before)
    }

    var replacement: Data { Data(ClaudeJSONFixture.oauthAccount(tag: "B", email: "b@example.com").utf8) }

    func makeStale(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: url.path)
    }

    @Test func staleNonEmptyLockDirectoryTimesOut() throws {
        let lock = dir.file(".claude.json.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: lock.appendingPathComponent("inner"))
        try makeStale(lock)
        #expect(throws: TerminalAccountError.lockTimeout) { try file.replaceOAuthAccount(with: replacement, lockTimeout: 0.2) }
    }

    @Test func staleLockThatIsARegularFileTimesOut() throws {
        let lock = dir.file(".claude.json.lock")
        try Data("x".utf8).write(to: lock)
        try makeStale(lock)
        #expect(throws: TerminalAccountError.lockTimeout) { try file.replaceOAuthAccount(with: replacement, lockTimeout: 0.2) }
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted()
    }

    @Test func noTempOrLockLeftAfterFailures() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.file(".claude.json").path)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try file.replaceOAuthAccount(with: replacement, beforeSwap: { throw Boom() }) }
        #expect(try names() == [".claude.json"])

        #expect(throws: TerminalAccountError.concurrentModification) {
            try file.replaceOAuthAccount(with: replacement, maxAttempts: 2) {
                let current = try Data(contentsOf: dir.file(".claude.json"))
                try (current + Data(" ".utf8)).write(to: dir.file(".claude.json"))
            }
        }
        #expect(try names() == [".claude.json"])

        let array = TerminalAccountFile(url: dir.file("array.json"))
        try Data("[]".utf8).write(to: dir.file("array.json"))
        #expect(throws: TerminalAccountError.notAnObject) { try array.replaceOAuthAccount(with: replacement) }
        #expect(try names() == [".claude.json", "array.json"])

        try file.replaceOAuthAccount(with: replacement)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.file(".claude.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try names() == [".claude.json", "array.json"])
    }

    @Test func symlinkedFileIsUpdatedThroughTheLink() throws {
        let other = try TempDir()
        let target = other.file("real.json")
        try Data(ClaudeJSONFixture.file(tag: "A", email: "you@work.example").utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = dir.file("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = TerminalAccountFile(url: link)
        try linked.replaceOAuthAccount(with: replacement)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        #expect((o["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "b@example.com")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try linked.currentIdentity()?.email == "b@example.com")
    }

    @Test func invalidOrUnreadableFileThrowsButMissingIsNil() throws {
        try Data("{not json".utf8).write(to: dir.file("bad.json"))
        #expect(throws: (any Error).self) { try TerminalAccountFile(url: dir.file("bad.json")).currentIdentity() }
        try FileManager.default.createDirectory(at: dir.file("adir.json"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try TerminalAccountFile(url: dir.file("adir.json")).currentIdentity() }
        #expect(try TerminalAccountFile(url: dir.file("missing.json")).currentIdentity() == nil)
    }

    @Test func invalidReplacementIsRejectedBeforeLocking() throws {
        for bad in ["{}", "[]", "nope", #"{"accountUuid":"x"}"#] {
            #expect(throws: (any Error).self) { try file.replaceOAuthAccount(with: Data(bad.utf8)) }
        }
        #expect(try names() == [".claude.json"])
    }

    @Test func replacePreservesEveryOtherValueExactly() throws {
        let raw = #"{"pi":3.14159,"big":12345678901234,"t":true,"f":false,"n":null,"s":"h\u00e9llo \ud83d\ude80 \/ path","arr":[1,[2,{"k":[null,0.5]}],"x"],"nested":{"a":{"b":[true,{"c":"d"}]}},"oauthAccount":{"accountUuid":"old","organizationUuid":"o"}}"#
        try Data(raw.utf8).write(to: dir.file(".claude.json"))
        let before = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary).mutableCopy() as! NSMutableDictionary
        try file.replaceOAuthAccount(with: replacement)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.file(".claude.json"))) as? NSDictionary).mutableCopy() as! NSMutableDictionary
        before.removeObject(forKey: "oauthAccount")
        after.removeObject(forKey: "oauthAccount")
        #expect(before == after)
    }

    @Test func importerAddsTerminalAccountOnceAndKeepsLabel() throws {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try #require(try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now))
        #expect(first.id == "acc-A:org-A")
        #expect(first.label == "Work")
        #expect(first.plan == "Max 20x")
        try store.update(id: first.id) { $0.label = "Work" }
        let second = try #require(try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now))
        #expect(second.label == "Work")
        #expect(try store.load().count == 1)
        #expect(try store.credentials(for: first.id) == nil)
    }

    @Test func importerLeavesAnUnchangedAccountListAlone() throws {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now)
        // Same accounts, different bytes: a rewrite would drop the trailing newline.
        let marked = try Data(contentsOf: dir.file("accounts.json")) + Data("\n".utf8)
        try marked.write(to: dir.file("accounts.json"))
        let again = try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now + 300)
        #expect(try Data(contentsOf: dir.file("accounts.json")) == marked)
        #expect(again == (try store.account(id: "acc-A:org-A")))
    }

    @Test func importerSavesWhatChangedInClaudeJSON() throws {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: InMemorySecretStore())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now)
        let renamed = ClaudeJSONFixture.file(tag: "A", email: "you@work.example")
            .replacingOccurrences(of: #""displayName":"Jeff""#, with: #""displayName":"Dev""#)
        try Data(renamed.utf8).write(to: dir.file(".claude.json"))
        try TerminalAccountImporter.importIfNeeded(store: store, terminal: file, now: now + 300)
        #expect(try store.account(id: "acc-A:org-A")?.displayName == "Dev")
    }
}
