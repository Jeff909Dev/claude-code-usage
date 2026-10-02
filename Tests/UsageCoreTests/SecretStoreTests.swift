import Foundation
import Testing
@testable import UsageCore

struct InMemorySecretStoreTests {
    @Test func roundTripsAndDeletes() throws {
        let s = InMemorySecretStore()
        #expect(try s.read(service: "svc", account: "a") == nil)
        try s.write(service: "svc", account: "a", data: Data("x".utf8))
        #expect(try s.read(service: "svc", account: "a") == Data("x".utf8))
        #expect(s.allKeys == ["svc|a"])
        try s.delete(service: "svc", account: "a")
        try s.delete(service: "svc", account: "a")
        #expect(try s.read(service: "svc", account: "a") == nil)
    }
}

/// Talks to the real login Keychain, but only under a unique `ClaudeUsageTests …` service that it deletes.
struct SecurityCLIStoreTests {
    @Test func roundTripsThroughTheLoginKeychain() throws {
        let store = SecurityCLIStore()
        let service = "ClaudeUsageTests \(UUID().uuidString)"   // contains a space on purpose
        defer { try? store.delete(service: service, account: "tester") }

        #expect(try store.read(service: service, account: "tester") == nil)
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"x y \"q\""}}"#.utf8)
        try store.write(service: service, account: "tester", data: payload)
        #expect(try store.read(service: service, account: "tester") == payload)

        try store.write(service: service, account: "tester", data: Data("v2".utf8))
        #expect(try store.read(service: service, account: "tester") == Data("v2".utf8))

        try store.delete(service: service, account: "tester")
        #expect(try store.read(service: service, account: "tester") == nil)
    }

    @Test func largeValueOverExistingItemRoundTripsExactly() throws {
        let store = SecurityCLIStore()
        let service = "ClaudeUsageTests \(UUID().uuidString)"
        defer { try? store.delete(service: service, account: "tester") }
        try store.write(service: service, account: "tester", data: Data("small".utf8))
        let big = Data((#"{"claudeAiOauth":{"accessToken":""# + String(repeating: "a", count: 12_000) + #""}}"#).utf8)
        try store.write(service: service, account: "tester", data: big)
        #expect(try store.read(service: service, account: "tester") == big)
    }

    @Test func nonAsciiValueRoundTrips() throws {
        let store = SecurityCLIStore()
        let service = "ClaudeUsageTests \(UUID().uuidString)"
        defer { try? store.delete(service: service, account: "tester") }
        let payload = Data(#"{"name":"é"}"#.utf8) + Data([0x09])
        try store.write(service: service, account: "tester", data: payload)
        #expect(try store.read(service: service, account: "tester") == payload)
    }

    @Test func rejectsControlCharactersInNames() {
        let store = SecurityCLIStore()
        for bad in ["a\nb", "a\rb", "a\u{0}b", "a\tb"] {
            #expect(throws: SecretStoreError.invalidName) {
                try store.write(service: bad, account: "tester", data: Data("x".utf8))
            }
            #expect(throws: SecretStoreError.invalidName) {
                try store.write(service: "ClaudeUsageTests x", account: bad, data: Data("x".utf8))
            }
            #expect(throws: SecretStoreError.invalidName) { _ = try store.read(service: bad, account: "a") }
            #expect(throws: SecretStoreError.invalidName) { try store.delete(service: "s", account: bad) }
        }
    }
}
