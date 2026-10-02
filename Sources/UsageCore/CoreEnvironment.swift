import Foundation

/// Wires the real (or fake) dependencies once; the app and the CLI both start here.
public struct CoreEnvironment: Sendable {
    public let paths: Paths
    public let now: any DateProvider
    public let secrets: any SecretStore
    public let api: UsageAPI
    public let store: AccountStore
    public let terminalFile: TerminalAccountFile
    public let terminalItem: TerminalKeychainItem
    public let credentials: CredentialProvider
    public let switcher: AccountSwitcher
    public let pricing: PricingTable

    /// `readOnly` never refreshes a token, and keeps the app's own state (account list, index) in a scratch copy
    /// under the temp directory, so polling and indexing change nothing of the user's. Switching and adding
    /// accounts still write credentials: read-only callers must not offer them.
    public static func live(readOnly: Bool = false) throws -> CoreEnvironment {
        var paths = Paths.live()
        if readOnly {
            paths = try readOnlyPaths(from: paths, scratch: FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeUsage-read-only", isDirectory: true))
        }
        try paths.ensureAppSupport()
        return make(paths: paths, secrets: SecurityCLIStore(), http: URLSessionHTTPClient(),
                    now: SystemDateProvider(), terminalItem: .live(), readOnly: readOnly)
    }

    /// `paths` with the app's state moved to `scratch`, seeded with the app's account list and pricing override
    /// (when they exist) so a read-only run sees every account without ever creating or changing the app's files.
    static func readOnlyPaths(from paths: Paths, scratch: URL) throws -> Paths {
        let copy = Paths(home: paths.home, appSupport: scratch)
        try copy.ensureAppSupport()
        let fm = FileManager.default
        for (source, target) in [(paths.accountsFile, copy.accountsFile), (paths.pricingOverride, copy.pricingOverride)] {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
        }
        return copy
    }

    public static func make(paths: Paths, secrets: any SecretStore, http: any HTTPClient, now: any DateProvider,
                            terminalItem: TerminalKeychainItem, readOnly: Bool) -> CoreEnvironment {
        let api = UsageAPI(http: http, now: now)
        let store = AccountStore(fileURL: paths.accountsFile, secrets: secrets)
        let terminalFile = TerminalAccountFile(url: paths.claudeJSON)
        let credentials = CredentialProvider(store: store, secrets: secrets, terminalItem: terminalItem,
                                             refresher: TokenRefresher(http: http, now: now), now: now,
                                             allowRefresh: !readOnly)
        let switcher = AccountSwitcher(store: store, secrets: secrets, terminalItem: terminalItem,
                                       terminalFile: terminalFile, now: now)
        return CoreEnvironment(paths: paths, now: now, secrets: secrets, api: api, store: store,
                               terminalFile: terminalFile, terminalItem: terminalItem, credentials: credentials,
                               switcher: switcher, pricing: PricingTable.load(override: paths.pricingOverride))
    }

    public func makeIndex() throws -> TranscriptIndex {
        try TranscriptIndex(databaseURL: paths.indexDatabase, projectsDir: paths.projectsDir, pricing: pricing)
    }

    /// Uses the same Keychain account as the terminal's item, so the login's item is found and cleaned up.
    public func makeLoginFlow(claude: URL) -> LoginFlow {
        LoginFlow(claude: claude, runner: FoundationProcessRunner(), secrets: secrets, api: api, store: store,
                  workRoot: paths.loginWorkRoot, keychainAccount: terminalItem.account, terminalFile: terminalFile,
                  now: now)
    }

    /// Removes what a crashed sign-in left under `login/`: its folder and its Keychain item. Call at launch, before any
    /// sign-in can start; it blocks on the Keychain, so off the main thread.
    public func sweepLoginLeftovers() {
        LoginFlow.sweepLeftovers(workRoot: paths.loginWorkRoot, secrets: secrets, keychainAccount: terminalItem.account)
    }

    public func terminalAccountID() -> String? {
        (try? terminalFile.currentIdentity())?.accountID
    }

    /// Unlists an account and deletes its app-owned login, but never the terminal's account. ~/.claude.json is read
    /// again here (a switch may have just moved the terminal), and when it can't be read nothing is removed.
    public func removeAccount(id: String) throws {
        if try terminalFile.currentIdentity()?.accountID == id { throw RemoveAccountError.inTerminal }
        try store.remove(id: id)
    }

    /// Without a usable custom path this runs the login shell (up to 3 s), so call it off the main thread.
    public func locateClaude(customPath: String?) -> URL? {
        if let customPath, FileManager.default.isExecutableFile(atPath: customPath) {
            return URL(fileURLWithPath: customPath)
        }
        return ClaudeBinaryLocator.locate(home: paths.home,
                                          pathEnv: ShellEnvironment.loginPATH() ?? ProcessInfo.processInfo.environment["PATH"])
    }
}

public enum RemoveAccountError: Error, Equatable {
    /// The terminal uses this account; switch it to another one first.
    case inTerminal
}
