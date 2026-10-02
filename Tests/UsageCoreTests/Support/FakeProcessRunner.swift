import Foundation
@testable import UsageCore

/// Pretends to be `claude auth login`: writes credentials where Claude Code would for CLAUDE_CONFIG_DIR.
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    enum Behavior: @unchecked Sendable {   // used as a Swift Testing argument; carries `any Error`
        case signIn(OAuthCredentials, oauthAccount: String)
        case exit(Int32)
        case fail(any Error)
    }

    let behavior: Behavior
    let secrets: InMemorySecretStore
    let keychainAccount: String
    private let lock = NSLock()
    private var calls: [(arguments: [String], environment: [String: String])] = []

    init(_ behavior: Behavior, secrets: InMemorySecretStore, keychainAccount: String = "tester") {
        self.behavior = behavior
        self.secrets = secrets
        self.keychainAccount = keychainAccount
    }

    var recorded: [(arguments: [String], environment: [String: String])] { lock.locked { calls } }

    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> Int32 {
        lock.locked { calls.append((arguments, environment)) }
        switch behavior {
        case .signIn(let creds, let oauthAccount):
            guard let dir = environment["CLAUDE_CONFIG_DIR"] else { return 99 }
            try secrets.write(service: ClaudeCodeKeychain.serviceName(configDir: dir), account: keychainAccount,
                              data: CredentialsJSON.merging(creds, into: nil))
            try Data(#"{"numStartups":1,"oauthAccount":\#(oauthAccount)}"#.utf8)
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(".claude.json"))
            return 0
        case .exit(let code):
            return code
        case .fail(let error):
            throw error
        }
    }
}
