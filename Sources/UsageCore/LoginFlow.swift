import Foundation

public enum LoginMethod: Sendable, Equatable {
    case google
    case email(String)
}

public enum LoginError: Error, Equatable {
    case failed(exitCode: Int32)
    case timedOut
    case cancelled
    case noCredentials
    /// The Claude binary is missing or could not be started.
    case couldNotLaunch
}

/// Adds an account by running Claude Code's own login (`claude auth login`) in a throwaway CLAUDE_CONFIG_DIR, so
/// the browser does Google / magic-link sign-in and we never see a password (spec §7).
public struct LoginFlow: Sendable {
    let claude: URL
    let runner: any ProcessRunner
    let secrets: any SecretStore
    let api: UsageAPI
    let store: AccountStore
    let workRoot: URL
    let keychainAccount: String
    let terminalFile: TerminalAccountFile
    let now: any DateProvider
    let loginPATH: @Sendable () -> String?
    let baseEnvironment: [String: String]

    /// `terminalFile` is Claude Code's `~/.claude.json`: it tells which account the terminal currently uses.
    public init(claude: URL, runner: any ProcessRunner, secrets: any SecretStore, api: UsageAPI, store: AccountStore,
                workRoot: URL, keychainAccount: String, terminalFile: TerminalAccountFile, now: any DateProvider,
                loginPATH: @escaping @Sendable () -> String? = { ShellEnvironment.loginPATH() },
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.claude = claude
        self.runner = runner
        self.secrets = secrets
        self.api = api
        self.store = store
        self.workRoot = workRoot
        self.keychainAccount = keychainAccount
        self.terminalFile = terminalFile
        self.now = now
        self.loginPATH = loginPATH
        self.baseEnvironment = baseEnvironment
    }

    public static func arguments(for method: LoginMethod) -> [String] {
        switch method {
        case .google: return ["auth", "login"]
        case .email(let email): return ["auth", "login", "--email", email]
        }
    }

    /// Variables that would make Claude Code skip or redirect the interactive login.
    static let strippedVariables = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                                    "CLAUDECODE", "CLAUDE_CONFIG_DIR"]

    static func childEnvironment(base: [String: String], loginPATH: String?, home: URL,
                                 configDir: String) -> [String: String] {
        var environment = base
        for name in strippedVariables { environment[name] = nil }
        environment["PATH"] = loginPATH ?? [base["PATH"], home.appendingPathComponent(".local/bin").path,
                                            "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        environment["CLAUDE_CONFIG_DIR"] = configDir
        return environment
    }

    /// Removes login directories (and their Keychain items) a crashed run left behind. Call at launch, never while
    /// a login is running.
    public func sweepLeftovers() {
        Self.sweepLeftovers(workRoot: workRoot, secrets: secrets, keychainAccount: keychainAccount)
    }

    static func sweepLeftovers(workRoot: URL, secrets: any SecretStore, keychainAccount: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workRoot.path) else { return }
        for name in names {
            let dir = workRoot.appendingPathComponent(name, isDirectory: true)
            try? secrets.delete(service: ClaudeCodeKeychain.serviceName(configDir: dir.path), account: keychainAccount)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public func addAccount(method: LoginMethod, timeout: TimeInterval = 600) async throws -> Account {
        let dir = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let service = ClaudeCodeKeychain.serviceName(configDir: dir.path)
        defer {
            try? secrets.delete(service: service, account: keychainAccount)
            try? FileManager.default.removeItem(at: dir)
        }

        let path = loginPATH
        let shellPATH = await Task.detached { path() }.value
        let environment = Self.childEnvironment(base: baseEnvironment, loginPATH: shellPATH,
                                                home: FileManager.default.homeDirectoryForCurrentUser,
                                                configDir: dir.path)
        let status: Int32
        do {
            status = try await runner.run(executable: claude, arguments: Self.arguments(for: method),
                                          environment: environment, timeout: timeout)
        } catch ProcessRunnerError.timedOut {
            throw LoginError.timedOut
        } catch is CancellationError {
            throw LoginError.cancelled
        } catch {
            throw LoginError.couldNotLaunch
        }
        guard status == 0 else { throw LoginError.failed(exitCode: status) }
        if Task.isCancelled { throw LoginError.cancelled }

        guard let creds = try readCredentials(service: service, dir: dir) else { throw LoginError.noCredentials }
        let oauthJSON: Data?
        do {
            oauthJSON = try TerminalAccountFile(url: dir.appendingPathComponent(".claude.json")).readOAuthAccountJSON()
        } catch {
            throw LoginError.noCredentials   // the login wrote something unreadable
        }
        let profile: Profile
        do {
            profile = try await api.profile(accessToken: creds.accessToken)
        } catch {
            if Task.isCancelled || error is CancellationError
                || error as? UsageAPIError == .network(String(URLError.cancelled.rawValue)) {
                throw LoginError.cancelled
            }
            throw error
        }
        return try register(profile: profile, creds: creds, oauthAccountJSON: oauthJSON)
    }

    /// Keychain read errors surface as themselves; unparseable content counts as "the login produced nothing".
    private func readCredentials(service: String, dir: URL) throws -> OAuthCredentials? {
        do {
            if let raw = try secrets.read(service: service, account: keychainAccount),
               let creds = try CredentialsJSON.claudeAiOauth(from: raw) {
                return creds
            }
            // Some setups store a credentials file inside the config dir instead of the Keychain.
            guard let raw = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")) else { return nil }
            return try CredentialsJSON.claudeAiOauth(from: raw)
        } catch let error as SecretStoreError {
            throw error
        } catch is CredentialsJSONError {
            throw LoginError.noCredentials
        } catch is DecodingError {
            throw LoginError.noCredentials
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            throw LoginError.noCredentials   // JSONSerialization failures
        }
    }

    private func register(profile: Profile, creds: OAuthCredentials, oauthAccountJSON: Data?) throws -> Account {
        let id = profile.accountID
        var account = try store.existingOrNew(
            id: id, accountUuid: profile.accountUuid, organizationUuid: profile.organizationUuid, email: profile.email,
            organizationName: profile.organizationName, now: now.now())
        account.email = profile.email
        account.displayName = profile.displayName
        account.organizationName = profile.organizationName
        account.organizationType = profile.organizationType
        account.rateLimitTier = creds.rateLimitTier ?? profile.rateLimitTier
        account.subscriptionType = creds.subscriptionType
        account.status = .ok
        // Only keep the login's oauthAccount when it really describes the account the profile reported.
        if let oauthAccountJSON, TerminalAccountFile.identity(fromOAuthAccountJSON: oauthAccountJSON)?.accountID == id {
            account.oauthAccountJSON = oauthAccountJSON
        }
        account.oauthAccountJSON = try account.oauthAccountPayload()

        // Credentials first: a failed write must not leave a listed `.ok` account without them.
        if (try? terminalFile.currentIdentity())?.accountID == id {
            // The terminal is on this account: Claude Code owns the token, so hand the new login to its item
            // (keeping mcpOAuth, every other key, and claudeAiOauth keys this app does not model).
            let service = ClaudeCodeKeychain.baseService
            let existing = try secrets.read(service: service, account: keychainAccount)
            try secrets.write(service: service, account: keychainAccount,
                              data: CredentialsJSON.merging(creds, into: existing, mode: .overlay))
        } else {
            try store.setCredentials(creds, for: id)
        }
        try store.upsert(account)
        return account
    }
}
