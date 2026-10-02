# Claude Usage (macOS menu bar app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app (plus a CLI over the same core) that shows every Claude account's limits (5 h session, week, week per model), pace, API-equivalent spend on this Mac, lets Jeff add accounts through Claude Code's official login and switch the terminal's account — then ships as a downloadable zip with a one-page site.

**Architecture:** One SwiftPM package. `UsageCore` (library, no UI) holds all logic behind small protocols (Keychain via `/usr/bin/security`, HTTP, process, clock, filesystem paths) so it is unit-tested with fakes. Two thin front-ends consume it: `ClaudeUsage` (SwiftUI `MenuBarExtra(.window)`) and `claude-usage-cli` (text output, used by agents for end-to-end checks on real data). Spend comes from an incremental SQLite index over `~/.claude/projects/**/*.jsonl`.

**Tech Stack:** Swift 6.3 (language mode 6), SwiftPM (tools 6.0), Swift Testing, SwiftUI/AppKit (macOS 14+), Foundation, CryptoKit, SQLite3 (system), ServiceManagement, UserNotifications. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-01-claude-usage-menubar-design.md` (read it before your task; it wins over this plan if they disagree — report the disagreement). Visual reference: `prototypes/menubar.html`, `prototypes/tokens.css` (open `prototypes/index.html` in a browser).

## Global Constraints

- Deployment target macOS 14.0 (`platforms: [.macOS(.v14)]`), `// swift-tools-version: 6.0`, Swift 6 language mode (strict concurrency). Core types are `Sendable`; app state is `@MainActor @Observable`.
- SwiftPM only — no `.xcodeproj`, no third-party packages. Allowed frameworks: Foundation, CryptoKit, SQLite3, SwiftUI, AppKit, ServiceManagement, UserNotifications.
- `UsageCore` never imports SwiftUI or AppKit.
- Never print, log, or put in error messages any access/refresh token. `OAuthCredentials.description` is redacted.
- Tests never touch the real `Claude Code-credentials*` Keychain items, the real `~/.claude.json`, or the real `~/.claude/projects`. Use `TempDir`, `InMemorySecretStore`, and — only for `SecurityCLIStore` integration tests — Keychain services prefixed `ClaudeUsageTests`.
- Agents may read real data only through `swift run claude-usage-cli --read-only status|accounts|stats` (Task 13) and by launching the app for a smoke test without clicking anything (Tasks 14 and 17). Agents never run `switch`, `login`, or the app's "Use in terminal"/"Add account" against real accounts — those are Jeff's manual QA (Task 17 checklist).
- Endpoints verbatim: usage `https://api.anthropic.com/api/oauth/usage`, profile `https://api.anthropic.com/api/oauth/profile`, header `anthropic-beta: oauth-2025-04-20`, token `https://platform.claude.com/v1/oauth/token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`.
- Claude Code Keychain item: service `Claude Code-credentials` (or `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR string)>`), account `NSUserName()`. App-owned items: service `Claude Usage`, account `Account.id` = `"<accountUuid>:<organizationUuid>"`, value = `claudeAiOauth` JSON.
- Writes to Claude Code's Keychain item replace only the `claudeAiOauth` key (keep `mcpOAuth` and every other key). Writes to `~/.claude.json` replace only `oauthAccount`, holding the `~/.claude.json.lock` directory lock, via temp file + `rename`, with compare-and-swap retry.
- App data lives in `~/Library/Application Support/ClaudeUsage/` (`accounts.json`, `index.sqlite`, `settings.json`, `snapshots.json`, `notifier.json`, `pricing.json` override, `login/`).
- Pricing verbatim from spec §9 ($/MTok): fable-5-1 10/50/0.25 · fable-5 10/50/1.00 · opus-5-5 4/20/0.20 · opus-5, opus-4-8, opus-4-7, opus-4-6 5/25/0.50 · sonnet-5-5, sonnet-5 2/10/0.20 · sonnet-4-6 3/15/0.30 · haiku-4-5 1/5/0.10. Cache write ×1.25 (5 m) and ×2.0 (1 h) of input; `speed:"fast"` ×2; longest-prefix match; unknown model = $0 and listed.
- Look: colors/type from `prototypes/tokens.css`; popover 340 pt wide, ≤ 640 pt tall, internal scroll; 12 pt padding; 0.5 pt dividers; CLI style = 11 pt SF Mono everywhere (default), Claude style = system sans 12 pt + mono digits. Section labels lowercase ("limits", "this mac"). UI copy in English.
- App name "Claude Usage", bundle id `com.jeff.ClaudeUsage`, version `0.1.0`. Release asset name exactly `ClaudeUsage.zip`.
- Run `swift build` and `swift test` before every commit; both must pass. One commit per task (conventional commit message given in the task).

## Review Focus

1. **`~/.claude.json` rewritten by a running `claude` while "Use in terminal" writes it** → neither change is lost; a stale `.claude.json.lock` from a crashed process does not block forever. Pinned in Task 8 (`replaceRetriesWhenFileChangesUnderneath`, `staleLockIsBroken`).
2. **A transcript line half-written when the indexer runs** → counted exactly once after the line completes; truncated/rewritten files don't double count. Pinned in Task 6 (`partialLastLineIsCountedOnceWhenCompleted`, `truncatedFileDoesNotDoubleCount`).
3. **The terminal account's token expired while no `claude` is running, or its refresh token revoked** → the app refreshes once without clobbering `mcpOAuth`; a revoked token shows "needs sign-in" and the menu bar shows `✻ !`. Pinned in Task 9 (`terminalExpiredRefreshesAndKeepsMcpOAuth`), Task 12 (`invalidGrantMarksNeedsSignIn`), Task 14 (`titleShowsBangWhenTerminalNeedsSignIn`).
4. **Reset times jitter by microseconds between fetches (`…04:00:00.474983` vs `…04:00:00.475185`) and windows with `resets_at: null` (no session started)** → notifications don't re-fire on every poll; the row shows "no active session" with no pace and no crash; times render in the user's time zone. Pinned in Task 12 (`jitteredResetDoesNotRefire`) and Task 4 (`nilResetShowsNoActiveSession`, `resetTextUsesCalendarTimeZone`).
5. **Model ids with suffixes or unknown (`claude-opus-5[1m]`, `claude-haiku-4-5-20251001`, `gpt_image_2_5`)** → priced by longest prefix; unknown ones cost $0 and are listed. Pinned in Task 5 (`pricesSuffixedModelIDs`) and Task 6 (`unknownModelIsListedAndCostsZero`).

---

### Task 1: Spike, package scaffold, paths and clock

**Files:**
- Create: `docs/notes/spike.md`
- Create: `Package.swift`, `Makefile`, `.gitignore`
- Create: `Sources/UsageCore/Environment.swift`, `Sources/UsageCore/Paths.swift`
- Create: `Sources/ClaudeUsage/App.swift` (bootstrap, replaced in Task 14)
- Create: `Sources/claude-usage-cli/CLI.swift` (bootstrap, replaced in Task 13)
- Create: `Tests/UsageCoreTests/Support/TempDir.swift`
- Test: `Tests/UsageCoreTests/PathsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public protocol DateProvider: Sendable { func now() -> Date }`, `public struct SystemDateProvider: DateProvider` (`public init()`), `public struct FixedDateProvider: DateProvider` (`public init(_ date: Date)`, `public var date: Date`).
  - `extension NSLock { func locked<T>(_ body: () throws -> T) rethrows -> T }` (internal).
  - `public struct Paths: Sendable, Equatable` with `public init(home: URL, appSupport: URL)`, `public static func live() -> Paths`, `public func ensureAppSupport() throws`, and `URL` properties `home`, `appSupport`, `claudeJSON`, `claudeConfigDir`, `projectsDir`, `accountsFile`, `indexDatabase`, `pricingOverride`, `settingsFile`, `snapshotsCache`, `notifierState`, `loginWorkRoot`.
  - Test helper `final class TempDir` (`init() throws`, `let url: URL`, `func file(_ name: String) -> URL`), removed on deinit.

- [ ] **Step 1: Run the spike checks (no user interaction, nothing is written outside `/tmp`)**

```bash
T=$(mktemp -d /tmp/cu-spike.XXXX)
CLAUDE_CONFIG_DIR="$T" claude auth status --json
ls -la "$T"
printf %s "$T" | shasum -a 256 | cut -c1-8
printf %s "/Users/$USER/.claude" | shasum -a 256 | cut -c1-8
security find-generic-password -s "Claude Code-credentials" 2>&1 | grep -E '"acct"|"svce"'
rm -rf "$T"
```

Expected: JSON with `"loggedIn": false`, `"configDirectory": "<T exactly as given, not symlink-resolved>"`; `$T` now contains `.claude.json` and a `.claude.json.lock` **directory**; the second hash names an existing `Claude Code-credentials-…` item; the Keychain item shows `"acct"<blob>="<your user>"`. Do not print the password (never pass `-w` here).

- [ ] **Step 2: Record the findings**

Create `docs/notes/spike.md`:

```markdown
# Spike notes (Task 1)

- `CLAUDE_CONFIG_DIR=<dir> claude auth status --json` reports `configDirectory` exactly as the given string
  (no symlink resolution) and creates `<dir>/.claude.json` → the account file for a custom config dir is
  `<dir>/.claude.json`.
- Claude Code guards `.claude.json` with a lock **directory** `<file>.lock` (proper-lockfile style). Our writer
  takes the same lock (mkdir; stale after 10 s).
- Keychain service for a custom config dir = `Claude Code-credentials-` + first 8 hex of
  sha256(<dir string>), e.g. `/Users/dev/.claude` → `c6b08108` (checked against an existing item).
- Keychain item account attribute = the macOS user name (`NSUserName()`).
- Not verifiable without a human: how `claude auth login` behaves without a TTY and whether `--email` forces a
  fresh claude.ai session. Covered by the manual QA checklist (Task 17).
```

- [ ] **Step 3: Create the package skeleton**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .executable(name: "claude-usage-cli", targets: ["claude-usage-cli"]),
    ],
    targets: [
        .target(name: "UsageCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClaudeUsage", dependencies: ["UsageCore"]),
        .executableTarget(name: "claude-usage-cli", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
```

`Sources/ClaudeUsage/App.swift`:

```swift
import SwiftUI

@main
struct ClaudeUsageApp: App {
    var body: some Scene {
        MenuBarExtra("✻") {
            Text("Claude Usage").padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

`Sources/claude-usage-cli/CLI.swift`:

```swift
import Foundation
import UsageCore

@main
enum CLI {
    static func main() {
        print("claude-usage-cli 0.1.0")
    }
}
```

`Makefile` (recipe lines start with a TAB):

```make
.PHONY: build test app run cli release clean

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

run: app
	open "build/Claude Usage.app"

cli:
	swift run claude-usage-cli $(ARGS)

release:
	./scripts/release.sh

clean:
	rm -rf .build build
```

`.gitignore`:

```gitignore
.build/
build/
.swiftpm/
*.xcodeproj
DerivedData/
.DS_Store
prototypes/shots/*.tmp.png
```

`Tests/UsageCoreTests/Support/TempDir.swift`:

```swift
import Foundation

/// A unique scratch directory, deleted when the object goes away.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
```

- [ ] **Step 4: Write the failing test**

`Tests/UsageCoreTests/PathsTests.swift`:

```swift
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
```

- [ ] **Step 5: Run it to see it fail**

Run: `swift test --filter PathsTests`
Expected: build error — `cannot find 'Paths' in scope`.

- [ ] **Step 6: Implement**

`Sources/UsageCore/Environment.swift`:

```swift
import Foundation

public protocol DateProvider: Sendable {
    func now() -> Date
}

public struct SystemDateProvider: DateProvider {
    public init() {}
    public func now() -> Date { Date() }
}

public struct FixedDateProvider: DateProvider {
    public var date: Date
    public init(_ date: Date) { self.date = date }
    public func now() -> Date { date }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
```

`Sources/UsageCore/Paths.swift`:

```swift
import Foundation

public struct Paths: Sendable, Equatable {
    public var home: URL
    public var appSupport: URL

    public init(home: URL, appSupport: URL) {
        self.home = home
        self.appSupport = appSupport
    }

    public static func live() -> Paths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        return Paths(home: fm.homeDirectoryForCurrentUser, appSupport: support)
    }

    public func ensureAppSupport() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var claudeConfigDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var projectsDir: URL { claudeConfigDir.appendingPathComponent("projects", isDirectory: true) }
    public var accountsFile: URL { appSupport.appendingPathComponent("accounts.json") }
    public var indexDatabase: URL { appSupport.appendingPathComponent("index.sqlite") }
    public var pricingOverride: URL { appSupport.appendingPathComponent("pricing.json") }
    public var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public var snapshotsCache: URL { appSupport.appendingPathComponent("snapshots.json") }
    public var notifierState: URL { appSupport.appendingPathComponent("notifier.json") }
    public var loginWorkRoot: URL { appSupport.appendingPathComponent("login", isDirectory: true) }
}
```

- [ ] **Step 7: Run tests and build**

Run: `swift test --filter PathsTests && swift build`
Expected: 4 tests pass; build succeeds for all three targets.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Makefile .gitignore Sources Tests docs/notes/spike.md
git commit -m "chore: scaffold SwiftPM package, paths and clock; record spike findings"
```

---

### Task 2: Secrets and credentials

**Files:**
- Create: `Sources/UsageCore/SecretStore.swift`, `Sources/UsageCore/SecurityCLIStore.swift`, `Sources/UsageCore/Credentials.swift`
- Create: `Tests/UsageCoreTests/Support/CredentialFactory.swift`
- Test: `Tests/UsageCoreTests/CredentialsTests.swift`, `Tests/UsageCoreTests/SecretStoreTests.swift`

**Interfaces:**
- Consumes: `NSLock.locked` (Task 1).
- Produces:
  - `public protocol SecretStore: Sendable { func read(service: String, account: String) throws -> Data?; func write(service: String, account: String, data: Data) throws; func delete(service: String, account: String) throws }` — `read` returns `nil` when missing; `delete` of a missing item is not an error.
  - `public enum SecretStoreError: Error, Equatable { case commandFailed(operation: String, status: Int32) }`
  - `public final class InMemorySecretStore: SecretStore, @unchecked Sendable` — `public init(_ items: [String: Data] = [:])`, `public static func key(service: String, account: String) -> String` (`"service|account"`), `public var allKeys: [String]` (sorted).
  - `public struct SecurityCLIStore: SecretStore` — `public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"))`.
  - `public struct OAuthCredentials: Codable, Sendable, Equatable, CustomStringConvertible` — `accessToken: String`, `refreshToken: String`, `expiresAt: Int64` (ms), `refreshTokenExpiresAt: Int64?`, `scopes: [String]`, `subscriptionType: String?`, `rateLimitTier: String?`; `public init(...)` with all fields; `public var expiresAtDate: Date`.
  - `public enum CredentialsJSON { static let oauthKey = "claudeAiOauth"; static func claudeAiOauth(from raw: Data) throws -> OAuthCredentials?; static func merging(_ creds: OAuthCredentials, into raw: Data?) throws -> Data }` and `public enum CredentialsJSONError: Error, Equatable { case notAnObject }`.
  - `public enum ClaudeCodeKeychain { static let baseService = "Claude Code-credentials"; static func serviceName(configDir: String?) -> String }`.
  - Test helper `extension OAuthCredentials { static func fake(_ tag: String, expiresAt: Int64 = 1_790_907_890_004, refreshTokenExpiresAt: Int64? = 1_792_663_758_004) -> OAuthCredentials }` → tokens `"at-<tag>"`, `"rt-<tag>"`.

- [ ] **Step 1: Write the failing tests**

`Tests/UsageCoreTests/Support/CredentialFactory.swift`:

```swift
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
```

`Tests/UsageCoreTests/CredentialsTests.swift`:

```swift
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

    @Test func mergeIntoNothingCreatesObject() throws {
        let b = OAuthCredentials.fake("B")
        #expect(try CredentialsJSON.claudeAiOauth(from: CredentialsJSON.merging(b, into: nil)) == b)
    }

    @Test func descriptionNeverContainsTokens() {
        let c = OAuthCredentials.fake("secret")
        #expect(!String(describing: c).contains("at-secret"))
        #expect(!"\(c)".contains("rt-secret"))
    }
}
```

`Tests/UsageCoreTests/SecretStoreTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "CredentialsTests|SecretStoreTests|SecurityCLIStoreTests"`
Expected: build errors — `cannot find 'OAuthCredentials' in scope`.

- [ ] **Step 3: Implement**

`Sources/UsageCore/SecretStore.swift`:

```swift
import Foundation

public protocol SecretStore: Sendable {
    /// Returns nil when the item does not exist.
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    /// Deleting a missing item is not an error.
    func delete(service: String, account: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case commandFailed(operation: String, status: Int32)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    public init(_ items: [String: Data] = [:]) { self.items = items }

    public static func key(service: String, account: String) -> String { "\(service)|\(account)" }

    public func read(service: String, account: String) throws -> Data? {
        lock.locked { items[Self.key(service: service, account: account)] }
    }

    public func write(service: String, account: String, data: Data) throws {
        lock.locked { items[Self.key(service: service, account: account)] = data }
    }

    public func delete(service: String, account: String) throws {
        lock.locked { items[Self.key(service: service, account: account)] = nil }
    }

    public var allKeys: [String] { lock.locked { items.keys.sorted() } }
}
```

`Sources/UsageCore/SecurityCLIStore.swift`:

```swift
import Foundation

/// Keychain access through /usr/bin/security. Items created this way trust the `security` tool, so Claude Code
/// (which uses the same tool) and this app read them without prompts — even though the app is ad-hoc signed and
/// its code signature changes on every build. Secret values never appear in argv or in errors.
public struct SecurityCLIStore: SecretStore {
    public let executable: URL
    static let itemNotFound: Int32 = 44

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security")) {
        self.executable = executable
    }

    public func read(service: String, account: String) throws -> Data? {
        let result = try run(["find-generic-password", "-s", service, "-a", account, "-w"], stdin: nil)
        if result.status == Self.itemNotFound { return nil }
        guard result.status == 0 else { throw SecretStoreError.commandFailed(operation: "read", status: result.status) }
        var out = result.stdout
        if out.last == 0x0A { out.removeLast() }
        return out
    }

    public func write(service: String, account: String, data: Data) throws {
        // Interactive mode reads the command from stdin, keeping the secret out of `ps`.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(Self.quote(service)) -a \(Self.quote(account)) -X \(hex)\n"
        let result = try run(["-i"], stdin: Data(command.utf8))
        // `security -i` may exit 0 even when a command fails, so verify by reading back.
        guard result.status == 0, try read(service: service, account: account) == data else {
            throw SecretStoreError.commandFailed(operation: "write", status: result.status)
        }
    }

    public func delete(service: String, account: String) throws {
        let result = try run(["delete-generic-password", "-s", service, "-a", account], stdin: nil)
        guard result.status == 0 || result.status == Self.itemNotFound else {
            throw SecretStoreError.commandFailed(operation: "delete", status: result.status)
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(_ arguments: [String], stdin: Data?) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
```

If `roundTripsThroughTheLoginKeychain` fails only because `security -i` does not honor the quoted service name, replace the body of `write` with the argv form `run(["add-generic-password", "-U", "-s", service, "-a", account, "-X", hex], stdin: nil)` followed by the same read-back check (the hex secret is then visible to `ps` for a few milliseconds, as in older Claude Code versions), and note it in `docs/notes/spike.md`.

`Sources/UsageCore/Credentials.swift`:

```swift
import CryptoKit
import Foundation

public struct OAuthCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since 1970, as Claude Code stores it.
    public var expiresAt: Int64
    public var refreshTokenExpiresAt: Int64?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Int64, refreshTokenExpiresAt: Int64?,
                scopes: [String], subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var expiresAtDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

extension OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OAuthCredentials(expiresAt: \(expiresAt), scopes: \(scopes.count), tokens: <redacted>)"
    }
    public var debugDescription: String { description }
}

public enum CredentialsJSONError: Error, Equatable {
    case notAnObject
}

/// Reads and writes the JSON blob Claude Code keeps in its Keychain item:
/// `{"claudeAiOauth": {...}, "mcpOAuth": {...}, ...}`.
public enum CredentialsJSON {
    public static let oauthKey = "claudeAiOauth"

    public static func claudeAiOauth(from raw: Data) throws -> OAuthCredentials? {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw CredentialsJSONError.notAnObject
        }
        guard let inner = object[oauthKey] else { return nil }
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        return try JSONDecoder().decode(OAuthCredentials.self, from: innerData)
    }

    /// Replaces only `claudeAiOauth`; every other top-level key (e.g. `mcpOAuth`) is kept as is.
    public static func merging(_ creds: OAuthCredentials, into raw: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let raw, !raw.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw CredentialsJSONError.notAnObject
            }
            object = existing
        }
        object[oauthKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(creds))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

public enum ClaudeCodeKeychain {
    public static let baseService = "Claude Code-credentials"

    /// Claude Code suffixes the service with the first 8 hex chars of sha256(CLAUDE_CONFIG_DIR) when it is set.
    public static func serviceName(configDir: String?) -> String {
        guard let configDir else { return baseService }
        let hex = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "CredentialsTests|SecretStoreTests|SecurityCLIStoreTests"`
Expected: all pass (the Keychain test leaves no `ClaudeUsageTests` item: `security dump-keychain | grep -c ClaudeUsageTests` prints `0`).

- [ ] **Step 5: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): keychain secret stores and Claude Code credential JSON handling"
```

---

### Task 3: Usage API client

**Files:**
- Create: `Sources/UsageCore/HTTPClient.swift`, `Sources/UsageCore/UsageModels.swift`, `Sources/UsageCore/ISODate.swift`, `Sources/UsageCore/UsageAPI.swift`
- Create: `Tests/UsageCoreTests/Support/FakeHTTPClient.swift`, `Tests/UsageCoreTests/Support/Fixtures.swift`
- Test: `Tests/UsageCoreTests/UsageAPITests.swift`

**Interfaces:**
- Consumes: `DateProvider` (Task 1).
- Produces:
  - `public protocol HTTPClient: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`; `public struct URLSessionHTTPClient: HTTPClient` (`public init(session: URLSession = .shared)`).
  - `public enum ISODate { public static func parse(_ s: String) -> Date? }` — any number of fractional digits, `Z` or `±HH:MM`.
  - `public struct UsageLimit: Codable, Sendable, Equatable, Identifiable` — `id: String` (`kind[:model][:surface]`), `kind: String`, `title: String`, `percent: Double`, `severity: String?`, `resetsAt: Date?`, `windowSeconds: TimeInterval`, `isActive: Bool`, `modelName: String?`; `static let sessionSeconds: TimeInterval = 18_000`, `static let weekSeconds: TimeInterval = 604_800`.
  - `public struct SurfaceShare: Codable, Sendable, Equatable` — `key`, `displayName`, `percent: Double`.
  - `public struct UsageSnapshot: Codable, Sendable, Equatable` — `limits: [UsageLimit]`, `surfaces: [SurfaceShare]`, `extraUsageEnabled: Bool`, `fetchedAt: Date`; `var session: UsageLimit?` (kind `session`); `var highestWeekly: UsageLimit?` (max percent among week-window limits).
  - `public struct Profile: Codable, Sendable, Equatable` — `accountUuid`, `email`, `displayName?`, `fullName?`, `organizationUuid`, `organizationName?`, `organizationType?`, `rateLimitTier?`, `subscriptionStatus?`, `hasClaudeMax: Bool`, `hasClaudePro: Bool`; `var accountID: String` (`"<accountUuid>:<organizationUuid>"`).
  - `public enum UsageAPIError: Error, Equatable, Sendable { case unauthorized, rateLimited(retryAfter: TimeInterval?), http(Int), decoding(String), network(String) }`.
  - `public struct UsageAPI: Sendable` — `public init(http: any HTTPClient, now: any DateProvider)`, `public func usage(accessToken: String) async throws -> UsageSnapshot`, `public func profile(accessToken: String) async throws -> Profile`, `public static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot`, `public static func decodeProfile(_ data: Data) throws -> Profile`; constants `baseURL`, `usagePath = "/api/oauth/usage"`, `profilePath = "/api/oauth/profile"`, `betaHeader = "oauth-2025-04-20"`.
  - Test helpers: `final class FakeHTTPClient: HTTPClient, @unchecked Sendable` with `struct Stub { status: Int; body: Data; headers: [String: String] }`, `init(_ stubs: [Stub])`, `var onSend: (@Sendable (URLRequest) -> Void)?`, `var error: (any Error)?`, `var requests: [URLRequest]`; `static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Stub`. `enum Fixtures { static let usageJSON: String; static func profileJSON(accountUuid: String = "acc-A", email: String = "you@work.example", orgUuid: String = "org-A", orgName: String = "you@work.example's Organization") -> String }`.

- [ ] **Step 1: Add test support**

`Tests/UsageCoreTests/Support/FakeHTTPClient.swift`:

```swift
import Foundation
@testable import UsageCore

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Stub {
        Stub(status: status, body: Data(body.utf8), headers: headers)
    }

    private let lock = NSLock()
    private var queue: [Stub]
    private var recorded: [URLRequest] = []
    var onSend: (@Sendable (URLRequest) -> Void)?
    var error: (any Error)?

    init(_ stubs: [Stub]) { queue = stubs }

    var requests: [URLRequest] { lock.locked { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onSend?(request)
        return try lock.locked {
            recorded.append(request)
            if let error { throw error }
            guard !queue.isEmpty else { throw URLError(.resourceUnavailable) }
            let stub = queue.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                           headerFields: stub.headers)!
            return (stub.body, response)
        }
    }
}
```

`Tests/UsageCoreTests/Support/Fixtures.swift` (shape of the live response from 2026-10-01; contains no secrets):

```swift
enum Fixtures {
    static let usageJSON = #"""
    {
      "five_hour": {"utilization": 25.0, "resets_at": "2026-10-01T22:30:00.474962+00:00", "limit_dollars": null},
      "seven_day": {"utilization": 54.0, "resets_at": "2026-10-06T04:00:00.474983+00:00"},
      "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null,
      "tangelo": null, "iguana_necktie": null, "amber_gauge": null,
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 25, "severity": "normal",
         "resets_at": "2026-10-01T22:30:00.474962+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 54, "severity": "normal",
         "resets_at": "2026-10-06T04:00:00.474983+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 64, "severity": "normal",
         "resets_at": "2026-10-06T04:00:00.475185+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
      ],
      "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "enabled": false},
      "member_dashboard_available": false,
      "seven_day_breakdown": {
        "as_of": "2026-10-01T19:59:41.660782+00:00",
        "rows": [
          {"key": "claude_code", "display_name": "Claude Code", "percent": 100},
          {"key": "chat", "display_name": "Chats", "percent": 0},
          {"key": "cowork", "display_name": "Cowork", "percent": 0},
          {"key": "other", "display_name": "Other", "percent": 0}
        ]
      }
    }
    """#

    static func profileJSON(accountUuid: String = "acc-A", email: String = "you@work.example",
                            orgUuid: String = "org-A",
                            orgName: String = "you@work.example's Organization") -> String {
        """
        {"account": {"uuid": "\(accountUuid)", "email": "\(email)", "display_name": "Jeff", "full_name": "Jeff",
                     "has_claude_max": true, "has_claude_pro": false, "created_at": "2025-01-01T00:00:00Z"},
         "organization": {"uuid": "\(orgUuid)", "name": "\(orgName)", "organization_type": "claude_max",
                          "rate_limit_tier": "default_claude_max_20x", "subscription_status": "active",
                          "billing_type": "stripe_subscription"}}
        """
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/UsageAPITests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct ISODateTests {
    @Test func parsesMicrosecondsWithOffset() throws {
        let d = try #require(ISODate.parse("2026-10-01T22:30:00.474962+00:00"))
        #expect(abs(d.timeIntervalSince1970 - 1_790_893_800.474962) < 0.0005)
    }
    @Test func parsesMillisWithZ() throws {
        let d = try #require(ISODate.parse("2026-10-01T15:27:38.176Z"))
        #expect(abs(d.timeIntervalSince1970 - 1_790_868_458.176) < 0.0005)
    }
    @Test func parsesWithoutFraction() {
        #expect(ISODate.parse("2026-10-06T04:00:00Z") == Date(timeIntervalSince1970: 1_791_259_200))
    }
    @Test func rejectsGarbage() { #expect(ISODate.parse("tomorrow") == nil) }
}

struct UsageAPITests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_884_800))

    @Test func decodesLiveShapeInDisplayOrder() throws {
        let s = try UsageAPI.decodeUsage(Data(Fixtures.usageJSON.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.kind) == ["session", "weekly_all", "weekly_scoped"])
        #expect(s.limits.map(\.title) == ["Session · 5h", "Week · all models", "Week · Fable"])
        #expect(s.limits.map(\.percent) == [25, 54, 64])
        #expect(s.limits.map(\.id) == ["session", "weekly_all", "weekly_scoped:Fable"])
        #expect(s.limits[0].windowSeconds == UsageLimit.sessionSeconds)
        #expect(s.limits[2].windowSeconds == UsageLimit.weekSeconds)
        #expect(s.limits[2].modelName == "Fable")
        #expect(s.limits[2].isActive)
        #expect(abs(s.limits[0].resetsAt!.timeIntervalSince1970 - 1_790_893_800.474962) < 0.001)
        #expect(s.surfaces.first == SurfaceShare(key: "claude_code", displayName: "Claude Code", percent: 100))
        #expect(s.extraUsageEnabled == false)
        #expect(s.session?.percent == 25)
        #expect(s.highestWeekly?.percent == 64)
        #expect(s.fetchedAt == now.now())
    }

    @Test func toleratesUnknownKindsBrokenEntriesAndStringSurfaces() throws {
        let json = #"""
        {"limits": [
          {"kind": 5},
          {"kind": "mystery_meter", "group": "daily", "percent": 10, "resets_at": null},
          {"kind": "weekly_scoped", "group": "weekly", "percent": 30, "scope": {"model": null, "surface": "cowork"}}
        ]}
        """#
        let s = try UsageAPI.decodeUsage(Data(json.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.title) == ["Week · cowork", "Mystery meter"])
        #expect(s.limits[1].resetsAt == nil)
    }

    @Test func fallsBackToLegacyWindowsWithoutLimitsArray() throws {
        let json = #"{"five_hour": {"utilization": 12, "resets_at": "2026-10-01T22:30:00Z"}, "seven_day": {"utilization": 40, "resets_at": null}, "seven_day_opus": {"utilization": 70, "resets_at": null}}"#
        let s = try UsageAPI.decodeUsage(Data(json.utf8), fetchedAt: now.now())
        #expect(s.limits.map(\.title) == ["Session · 5h", "Week · all models", "Week · Opus"])
        #expect(s.limits.map(\.percent) == [12, 40, 70])
    }

    @Test func sendsBearerAndBetaHeaderToUsageEndpoint() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.usageJSON)])
        _ = try await UsageAPI(http: http, now: now).usage(accessToken: "tok")
        let r = try #require(http.requests.first)
        #expect(r.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func mapsHTTPErrors() async {
        func status(_ code: Int, headers: [String: String] = [:]) async -> UsageAPIError? {
            let http = FakeHTTPClient([FakeHTTPClient.json(code, "{}", headers: headers)])
            do { _ = try await UsageAPI(http: http, now: now).usage(accessToken: "t"); return nil }
            catch { return error as? UsageAPIError }
        }
        #expect(await status(401) == .unauthorized)
        #expect(await status(403) == .unauthorized)
        #expect(await status(429, headers: ["Retry-After": "120"]) == .rateLimited(retryAfter: 120))
        #expect(await status(500) == .http(500))
    }

    @Test func mapsTransportErrorsToNetwork() async {
        let http = FakeHTTPClient([])
        http.error = URLError(.notConnectedToInternet)
        await #expect(throws: UsageAPIError.network(String(URLError.notConnectedToInternet.rawValue))) {
            _ = try await UsageAPI(http: http, now: now).usage(accessToken: "t")
        }
    }

    @Test func decodesProfile() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.profileJSON())])
        let p = try await UsageAPI(http: http, now: now).profile(accessToken: "t")
        #expect(p.accountID == "acc-A:org-A")
        #expect(p.email == "you@work.example")
        #expect(p.organizationType == "claude_max")
        #expect(p.rateLimitTier == "default_claude_max_20x")
        #expect(p.hasClaudeMax)
        #expect(http.requests.first?.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter "ISODateTests|UsageAPITests"`
Expected: build errors — `cannot find 'UsageAPI' in scope`.

- [ ] **Step 4: Implement**

`Sources/UsageCore/HTTPClient.swift`:

```swift
import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
```

`Sources/UsageCore/ISODate.swift`:

```swift
import Foundation

public enum ISODate {
    /// Parses ISO 8601 timestamps with any number of fractional digits ("…00.474962+00:00", "…38.176Z").
    public static func parse(_ string: String) -> Date? {
        var base = string
        var fraction = 0.0
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            fraction = Double("0." + digits) ?? 0
            base = String(string[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base)?.addingTimeInterval(fraction)
    }
}
```

`Sources/UsageCore/UsageModels.swift`:

```swift
import Foundation

public struct UsageLimit: Codable, Sendable, Equatable, Identifiable {
    public static let sessionSeconds: TimeInterval = 5 * 3_600
    public static let weekSeconds: TimeInterval = 7 * 86_400

    public var id: String
    public var kind: String
    public var title: String
    public var percent: Double
    public var severity: String?
    public var resetsAt: Date?
    public var windowSeconds: TimeInterval
    public var isActive: Bool
    public var modelName: String?
}

public struct SurfaceShare: Codable, Sendable, Equatable {
    public var key: String
    public var displayName: String
    public var percent: Double
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var limits: [UsageLimit]
    public var surfaces: [SurfaceShare]
    public var extraUsageEnabled: Bool
    public var fetchedAt: Date

    public var session: UsageLimit? { limits.first { $0.kind == "session" } }

    public var highestWeekly: UsageLimit? {
        limits.filter { $0.windowSeconds == UsageLimit.weekSeconds }.max { $0.percent < $1.percent }
    }
}

public struct Profile: Codable, Sendable, Equatable {
    public var accountUuid: String
    public var email: String
    public var displayName: String?
    public var fullName: String?
    public var organizationUuid: String
    public var organizationName: String?
    public var organizationType: String?
    public var rateLimitTier: String?
    public var subscriptionStatus: String?
    public var hasClaudeMax: Bool
    public var hasClaudePro: Bool

    public var accountID: String { "\(accountUuid):\(organizationUuid)" }
}
```

`Sources/UsageCore/UsageAPI.swift`:

```swift
import Foundation

public enum UsageAPIError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case decoding(String)
    case network(String)
}

public struct UsageAPI: Sendable {
    public static let baseURL = URL(string: "https://api.anthropic.com")!
    public static let usagePath = "/api/oauth/usage"
    public static let profilePath = "/api/oauth/profile"
    public static let betaHeader = "oauth-2025-04-20"

    let http: any HTTPClient
    let now: any DateProvider

    public init(http: any HTTPClient, now: any DateProvider) {
        self.http = http
        self.now = now
    }

    public func usage(accessToken: String) async throws -> UsageSnapshot {
        try Self.decodeUsage(try await get(Self.usagePath, token: accessToken), fetchedAt: now.now())
    }

    public func profile(accessToken: String) async throws -> Profile {
        try Self.decodeProfile(try await get(Self.profilePath, token: accessToken))
    }

    func get(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.baseURL)!.absoluteURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as URLError {
            throw UsageAPIError.network(String(error.code.rawValue))
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw UsageAPIError.unauthorized
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPIError.rateLimited(retryAfter: retry)
        default: throw UsageAPIError.http(response.statusCode)
        }
    }

    // MARK: Decoding

    public static func decodeUsage(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let dto: UsageDTO
        do { dto = try JSONDecoder().decode(UsageDTO.self, from: data) }
        catch { throw UsageAPIError.decoding(String(describing: error)) }

        var limits = (dto.limits ?? []).compactMap(\.value).compactMap(limit(from:))
        if limits.isEmpty { limits = legacyLimits(dto) }
        limits = limits.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)

        let surfaces = (dto.seven_day_breakdown?.rows ?? []).map {
            SurfaceShare(key: $0.key, displayName: $0.display_name ?? $0.key, percent: $0.percent ?? 0)
        }
        return UsageSnapshot(limits: limits, surfaces: surfaces,
                             extraUsageEnabled: dto.extra_usage?.is_enabled ?? false, fetchedAt: fetchedAt)
    }

    public static func decodeProfile(_ data: Data) throws -> Profile {
        let dto: ProfileDTO
        do { dto = try JSONDecoder().decode(ProfileDTO.self, from: data) }
        catch { throw UsageAPIError.decoding(String(describing: error)) }
        return Profile(accountUuid: dto.account.uuid, email: dto.account.email,
                       displayName: dto.account.display_name, fullName: dto.account.full_name,
                       organizationUuid: dto.organization.uuid, organizationName: dto.organization.name,
                       organizationType: dto.organization.organization_type,
                       rateLimitTier: dto.organization.rate_limit_tier,
                       subscriptionStatus: dto.organization.subscription_status,
                       hasClaudeMax: dto.account.has_claude_max ?? false,
                       hasClaudePro: dto.account.has_claude_pro ?? false)
    }

    static func rank(_ kind: String) -> Int {
        switch kind {
        case "session": return 0
        case "weekly_all": return 1
        case "weekly_scoped": return 2
        default: return 3
        }
    }

    static func limit(from dto: UsageDTO.LimitDTO) -> UsageLimit? {
        guard let percent = dto.percent else { return nil }
        let model = dto.scope?.modelName
        let surface = dto.scope?.surfaceName
        let isSession = dto.kind == "session" || dto.group == "session"
        let title: String
        switch dto.kind {
        case "session": title = "Session · 5h"
        case "weekly_all": title = "Week · all models"
        case "weekly_scoped": title = "Week · " + (model ?? surface ?? "scoped")
        default:
            let words = dto.kind.replacingOccurrences(of: "_", with: " ")
            title = words.prefix(1).uppercased() + words.dropFirst()
        }
        return UsageLimit(id: [dto.kind, model, surface].compactMap { $0 }.joined(separator: ":"),
                          kind: dto.kind, title: title, percent: percent, severity: dto.severity,
                          resetsAt: dto.resets_at.flatMap(ISODate.parse),
                          windowSeconds: isSession ? UsageLimit.sessionSeconds : UsageLimit.weekSeconds,
                          isActive: dto.is_active ?? false, modelName: model)
    }

    static func legacyLimits(_ dto: UsageDTO) -> [UsageLimit] {
        let windows: [(UsageDTO.Window?, String, String, TimeInterval, String?)] = [
            (dto.five_hour, "session", "Session · 5h", UsageLimit.sessionSeconds, nil),
            (dto.seven_day, "weekly_all", "Week · all models", UsageLimit.weekSeconds, nil),
            (dto.seven_day_opus, "weekly_scoped", "Week · Opus", UsageLimit.weekSeconds, "Opus"),
            (dto.seven_day_sonnet, "weekly_scoped", "Week · Sonnet", UsageLimit.weekSeconds, "Sonnet"),
        ]
        return windows.compactMap { window, kind, title, seconds, model in
            guard let utilization = window?.utilization else { return nil }
            return UsageLimit(id: [kind, model].compactMap { $0 }.joined(separator: ":"), kind: kind, title: title,
                              percent: utilization, severity: nil,
                              resetsAt: window?.resets_at.flatMap(ISODate.parse), windowSeconds: seconds,
                              isActive: false, modelName: model)
        }
    }
}

/// Decodes T, or nil when this element is malformed — one bad limit must not hide the others.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

struct UsageDTO: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    struct LimitDTO: Decodable {
        let kind: String
        let group: String?
        let percent: Double?
        let severity: String?
        let resets_at: String?
        let is_active: Bool?
        let scope: ScopeDTO?
    }

    struct ScopeDTO: Decodable {
        struct Named: Decodable { let display_name: String? }
        enum CodingKeys: String, CodingKey { case model, surface }
        let modelName: String?
        let surfaceName: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelName = (try? c.decodeIfPresent(Named.self, forKey: .model))?.display_name
            let namedSurface = (try? c.decodeIfPresent(Named.self, forKey: .surface))?.display_name
            let plainSurface = try? c.decodeIfPresent(String.self, forKey: .surface)
            surfaceName = namedSurface ?? plainSurface
        }
    }

    struct Breakdown: Decodable {
        struct Row: Decodable {
            let key: String
            let display_name: String?
            let percent: Double?
        }
        let rows: [Row]?
    }

    struct Extra: Decodable { let is_enabled: Bool? }

    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let limits: [Failable<LimitDTO>]?
    let seven_day_breakdown: Breakdown?
    let extra_usage: Extra?
}

struct ProfileDTO: Decodable {
    struct AccountDTO: Decodable {
        let uuid: String
        let email: String
        let display_name: String?
        let full_name: String?
        let has_claude_max: Bool?
        let has_claude_pro: Bool?
    }
    struct OrganizationDTO: Decodable {
        let uuid: String
        let name: String?
        let organization_type: String?
        let rate_limit_tier: String?
        let subscription_status: String?
    }
    let account: AccountDTO
    let organization: OrganizationDTO
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "ISODateTests|UsageAPITests"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): usage and profile API client with tolerant decoding"
```

---

### Task 4: Pace, levels, recommender and text formatting

**Files:**
- Create: `Sources/UsageCore/Pace.swift`, `Sources/UsageCore/Recommender.swift`, `Sources/UsageCore/Format.swift`
- Create: `Tests/UsageCoreTests/Support/SnapshotFactory.swift`
- Test: `Tests/UsageCoreTests/PaceTests.swift`, `Tests/UsageCoreTests/RecommenderTests.swift`, `Tests/UsageCoreTests/FormatTests.swift`

**Interfaces:**
- Consumes: `UsageLimit`, `UsageSnapshot` (Task 3).
- Produces:
  - `public enum UsageLevel: Sendable, Equatable { case normal, warn, critical; static func of(percent: Double) -> UsageLevel }` (< 70, 70–89, ≥ 90).
  - `public enum PaceStatus: Sendable, Equatable { case unknown, onPace, ahead(points: Int, hitsLimitAt: Date?), under(points: Int) }`; `public struct Pace: Sendable, Equatable { var elapsedFraction: Double?; var status: PaceStatus }`; `public enum PaceCalculator { static let tolerance = 5.0; static func pace(for limit: UsageLimit, now: Date) -> Pace }`.
  - `public struct RecommendationCandidate: Sendable, Equatable` with `public init(accountID: String, isAvailable: Bool, isTerminal: Bool, snapshot: UsageSnapshot?)`; `public enum Recommender { static func headroom(_ s: UsageSnapshot, preferredModel: String?) -> Double; static func best(_ c: [RecommendationCandidate], preferredModel: String?) -> String? }`.
  - `public enum Format` with `percent(_:) -> String`, `money(micros: Int64) -> String`, `tokens(_ n: Int64) -> String`, `duration(_ seconds: TimeInterval) -> String`, `clock(_:calendar:)`, `dayClock(_:calendar:)`, `resetText(for limit: UsageLimit, now: Date, calendar: Calendar) -> String`, `paceLine(_ pace: Pace, percent: Double, calendar: Calendar) -> String`, `updatedAgo(_ date: Date?, now: Date) -> String`.
  - Test helper `extension UsageSnapshot { static func fake(session: Double = 25, weekly: Double = 54, fable: Double? = 64, sessionResets: Date? = Date(timeIntervalSince1970: 1_790_893_800), weeklyResets: Date? = Date(timeIntervalSince1970: 1_791_259_200), fetchedAt: Date = Date(timeIntervalSince1970: 1_790_870_400)) -> UsageSnapshot }` (limit ids `session`, `weekly_all`, `weekly_scoped:Fable`).

- [ ] **Step 1: Add the snapshot factory**

`Tests/UsageCoreTests/Support/SnapshotFactory.swift`:

```swift
import Foundation
@testable import UsageCore

extension UsageSnapshot {
    static func fake(session: Double = 25, weekly: Double = 54, fable: Double? = 64,
                     sessionResets: Date? = Date(timeIntervalSince1970: 1_790_893_800),
                     weeklyResets: Date? = Date(timeIntervalSince1970: 1_791_259_200),
                     fetchedAt: Date = Date(timeIntervalSince1970: 1_790_870_400)) -> UsageSnapshot {
        var limits = [
            UsageLimit(id: "session", kind: "session", title: "Session · 5h", percent: session, severity: nil,
                       resetsAt: sessionResets, windowSeconds: UsageLimit.sessionSeconds, isActive: false, modelName: nil),
            UsageLimit(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: weekly,
                       severity: nil, resetsAt: weeklyResets, windowSeconds: UsageLimit.weekSeconds,
                       isActive: false, modelName: nil),
        ]
        if let fable {
            limits.append(UsageLimit(id: "weekly_scoped:Fable", kind: "weekly_scoped", title: "Week · Fable",
                                     percent: fable, severity: nil, resetsAt: weeklyResets,
                                     windowSeconds: UsageLimit.weekSeconds, isActive: true, modelName: "Fable"))
        }
        return UsageSnapshot(limits: limits, surfaces: [], extraUsageEnabled: false, fetchedAt: fetchedAt)
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/PaceTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct PaceTests {
    let reset = Date(timeIntervalSince1970: 1_791_259_200)
    var start: Date { reset.addingTimeInterval(-UsageLimit.weekSeconds) }

    func weekly(_ percent: Double, resetsAt: Date?) -> UsageLimit {
        UsageLimit(id: "weekly_all", kind: "weekly_all", title: "Week · all models", percent: percent, severity: nil,
                   resetsAt: resetsAt, windowSeconds: UsageLimit.weekSeconds, isActive: false, modelName: nil)
    }

    @Test func levels() {
        #expect(UsageLevel.of(percent: 69.9) == .normal)
        #expect(UsageLevel.of(percent: 70) == .warn)
        #expect(UsageLevel.of(percent: 89) == .warn)
        #expect(UsageLevel.of(percent: 90) == .critical)
    }

    @Test func aheadOfPaceProjectsHundredPercentBeforeReset() throws {
        let now = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds)
        let pace = PaceCalculator.pace(for: weekly(54, resetsAt: reset), now: now)
        #expect(abs(try #require(pace.elapsedFraction) - 0.38) < 1e-9)
        guard case .ahead(let points, let hit) = pace.status else { Issue.record("expected ahead"); return }
        #expect(points == 16)
        let expected = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds * 100 / 54)
        #expect(abs(try #require(hit).timeIntervalSince(expected)) < 0.001)
    }

    @Test(arguments: [(40.0, PaceStatus.onPace), (10.0, PaceStatus.under(points: 28))])
    func onAndUnderPace(percent: Double, expected: PaceStatus) {
        let now = start.addingTimeInterval(0.38 * UsageLimit.weekSeconds)
        #expect(PaceCalculator.pace(for: weekly(percent, resetsAt: reset), now: now).status == expected)
    }

    @Test func aheadAtWindowStartHasNoProjection() {
        // Being ahead of pace always projects 100 % before the reset, except when no time has elapsed yet.
        #expect(PaceCalculator.pace(for: weekly(10, resetsAt: reset), now: start).status
                == .ahead(points: 10, hitsLimitAt: nil))
    }

    @Test func nilResetIsUnknown() {
        let pace = PaceCalculator.pace(for: weekly(0, resetsAt: nil), now: reset)
        #expect(pace == Pace(elapsedFraction: nil, status: .unknown))
    }
}
```

`Tests/UsageCoreTests/RecommenderTests.swift`:

```swift
import Testing
@testable import UsageCore

struct RecommenderTests {
    @Test func headroomUsesTightestRelevantLimit() {
        let s = UsageSnapshot.fake(session: 10, weekly: 54, fable: 64)
        #expect(Recommender.headroom(s, preferredModel: "Fable") == 36)
        #expect(Recommender.headroom(s, preferredModel: "Opus") == 46)
        #expect(Recommender.headroom(s, preferredModel: nil) == 46)
    }

    @Test func picksMostHeadroomAmongAvailableAccounts() {
        let candidates = [
            RecommendationCandidate(accountID: "work", isAvailable: true, isTerminal: true,
                                    snapshot: .fake(session: 25, weekly: 54, fable: 64)),
            RecommendationCandidate(accountID: "personal", isAvailable: true, isTerminal: false,
                                    snapshot: .fake(session: 0, weekly: 12, fable: 20)),
            RecommendationCandidate(accountID: "studio", isAvailable: true, isTerminal: false,
                                    snapshot: .fake(session: 88, weekly: 91, fable: 97)),
            RecommendationCandidate(accountID: "lab", isAvailable: false, isTerminal: false,
                                    snapshot: .fake(session: 0, weekly: 0, fable: 0)),
            RecommendationCandidate(accountID: "new", isAvailable: true, isTerminal: false, snapshot: nil),
        ]
        #expect(Recommender.best(candidates, preferredModel: "Fable") == "personal")
    }

    @Test func returnsNilWhenTerminalIsAlreadyBestOrTied() {
        let candidates = [
            RecommendationCandidate(accountID: "a", isAvailable: true, isTerminal: true, snapshot: .fake(weekly: 10, fable: 10)),
            RecommendationCandidate(accountID: "b", isAvailable: true, isTerminal: false, snapshot: .fake(weekly: 10, fable: 10)),
        ]
        #expect(Recommender.best(candidates, preferredModel: "Fable") == nil)
    }
}
```

`Tests/UsageCoreTests/FormatTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct FormatTests {
    var madrid: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_884_800) // 2026-10-01 20:00 UTC (22:00 Madrid)

    func limit(kind: String, resetsAt: Date?) -> UsageLimit {
        UsageLimit(id: kind, kind: kind, title: kind, percent: 0, severity: nil, resetsAt: resetsAt,
                   windowSeconds: kind == "session" ? UsageLimit.sessionSeconds : UsageLimit.weekSeconds,
                   isActive: false, modelName: nil)
    }

    @Test func numbers() {
        #expect(Format.percent(25.4) == "25%")
        #expect(Format.money(micros: 48_200_000) == "$48.20")
        #expect(Format.money(micros: 0) == "$0.00")
        #expect(Format.money(micros: 1_140_000_000) == "$1,140")
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1_260) == "1.3K")
        #expect(Format.tokens(950_000) == "950K")
        #expect(Format.tokens(18_400_000) == "18.4M")
        #expect(Format.duration(30) == "<1m")
        #expect(Format.duration(2_700) == "45m")
        #expect(Format.duration(9_000) == "2h 30m")
        #expect(Format.duration(273_600) == "3d 4h")
    }

    @Test func resetTextUsesCalendarTimeZone() {
        let soon = Date(timeIntervalSince1970: 1_790_893_800)   // 22:30 UTC = 00:30 Madrid
        #expect(Format.resetText(for: limit(kind: "session", resetsAt: soon), now: now, calendar: madrid)
                == "resets 00:30 (in 2h 30m)")
        let later = Date(timeIntervalSince1970: 1_791_259_200)  // Tue 04:00 UTC = 06:00 Madrid
        #expect(Format.resetText(for: limit(kind: "weekly_all", resetsAt: later), now: now, calendar: madrid)
                == "resets Tue 06:00")
    }

    @Test func nilResetShowsNoActiveSession() {
        #expect(Format.resetText(for: limit(kind: "session", resetsAt: nil), now: now, calendar: madrid) == "no active session")
        #expect(Format.resetText(for: limit(kind: "weekly_all", resetsAt: nil), now: now, calendar: madrid) == "not started")
    }

    @Test func paceLines() {
        let hit = Date(timeIntervalSince1970: 1_791_028_800)    // Sat 2026-10-03 12:00 UTC = 14:00 Madrid
        #expect(Format.paceLine(Pace(elapsedFraction: 0.3, status: .onPace), percent: 30, calendar: madrid) == "on pace")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.4, status: .under(points: 12)), percent: 28, calendar: madrid)
                == "12 pts under pace")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.38, status: .ahead(points: 16, hitsLimitAt: hit)), percent: 54,
                                calendar: madrid) == "ahead of pace +16 pts · 100% ≈ Sat 14:00")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.9, status: .ahead(points: 7, hitsLimitAt: nil)), percent: 97,
                                calendar: madrid) == "ahead of pace +7 pts")
        #expect(Format.paceLine(Pace(elapsedFraction: 0.5, status: .ahead(points: 50, hitsLimitAt: nil)), percent: 100,
                                calendar: madrid) == "limit reached")
        #expect(Format.paceLine(Pace(elapsedFraction: nil, status: .unknown), percent: 0, calendar: madrid) == "")
    }

    @Test func updatedAgo() {
        #expect(Format.updatedAgo(nil, now: now) == "not updated yet")
        #expect(Format.updatedAgo(now.addingTimeInterval(-20), now: now) == "updated just now")
        #expect(Format.updatedAgo(now.addingTimeInterval(-75), now: now) == "updated 1m ago")
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter "PaceTests|RecommenderTests|FormatTests"`
Expected: build errors — `cannot find 'PaceCalculator' in scope`.

- [ ] **Step 4: Implement**

`Sources/UsageCore/Pace.swift`:

```swift
import Foundation

public enum UsageLevel: Sendable, Equatable {
    case normal, warn, critical

    public static func of(percent: Double) -> UsageLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warn }
        return .normal
    }
}

public enum PaceStatus: Sendable, Equatable {
    case unknown
    case onPace
    case ahead(points: Int, hitsLimitAt: Date?)
    case under(points: Int)
}

public struct Pace: Sendable, Equatable {
    /// Fraction of the window already elapsed (0…1); nil when the window has no reset time.
    public var elapsedFraction: Double?
    public var status: PaceStatus
}

public enum PaceCalculator {
    public static let tolerance = 5.0

    public static func pace(for limit: UsageLimit, now: Date) -> Pace {
        guard let resetsAt = limit.resetsAt, limit.windowSeconds > 0 else {
            return Pace(elapsedFraction: nil, status: .unknown)
        }
        let start = resetsAt.addingTimeInterval(-limit.windowSeconds)
        let elapsed = min(max(now.timeIntervalSince(start), 0), limit.windowSeconds)
        let fraction = elapsed / limit.windowSeconds
        let delta = limit.percent - fraction * 100
        if abs(delta) <= tolerance { return Pace(elapsedFraction: fraction, status: .onPace) }
        if delta < 0 { return Pace(elapsedFraction: fraction, status: .under(points: Int((-delta).rounded()))) }

        var hit: Date?
        if limit.percent > 0, elapsed > 0 {
            let projected = start.addingTimeInterval(elapsed * 100 / limit.percent)
            if projected < resetsAt { hit = projected }
        }
        return Pace(elapsedFraction: fraction, status: .ahead(points: Int(delta.rounded()), hitsLimitAt: hit))
    }
}
```

`Sources/UsageCore/Recommender.swift`:

```swift
import Foundation

public struct RecommendationCandidate: Sendable, Equatable {
    public var accountID: String
    public var isAvailable: Bool
    public var isTerminal: Bool
    public var snapshot: UsageSnapshot?

    public init(accountID: String, isAvailable: Bool, isTerminal: Bool, snapshot: UsageSnapshot?) {
        self.accountID = accountID
        self.isAvailable = isAvailable
        self.isTerminal = isTerminal
        self.snapshot = snapshot
    }
}

public enum Recommender {
    /// Headroom of the tightest relevant limit: session, week (all models), and the week limit of the model the
    /// terminal uses most.
    public static func headroom(_ snapshot: UsageSnapshot, preferredModel: String?) -> Double {
        let relevant = snapshot.limits.filter { limit in
            switch limit.kind {
            case "session", "weekly_all": return true
            case "weekly_scoped":
                guard let preferredModel, let model = limit.modelName else { return false }
                return model.caseInsensitiveCompare(preferredModel) == .orderedSame
            default: return false
            }
        }
        return relevant.map { 100 - $0.percent }.min() ?? 100
    }

    /// The account to suggest, or nil when the terminal account is already (one of) the best.
    public static func best(_ candidates: [RecommendationCandidate], preferredModel: String?) -> String? {
        let scored = candidates.compactMap { c -> (RecommendationCandidate, Double)? in
            guard c.isAvailable, let snapshot = c.snapshot else { return nil }
            return (c, headroom(snapshot, preferredModel: preferredModel))
        }
        guard let top = scored.map(\.1).max() else { return nil }
        let winners = scored.filter { $0.1 == top }.map(\.0)
        if winners.contains(where: \.isTerminal) { return nil }
        return winners.first?.accountID
    }
}
```

`Sources/UsageCore/Format.swift`:

```swift
import Foundation

public enum Format {
    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    public static func money(micros: Int64) -> String {
        let dollars = Double(micros) / 1_000_000
        guard dollars >= 1_000 else { return String(format: "$%.2f", dollars) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: dollars.rounded())) ?? String(Int(dollars)))
    }

    public static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        switch n {
        case ..<1_000: return String(n)
        case ..<10_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "<1m" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }

    static func formatter(_ pattern: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f
    }

    public static func clock(_ date: Date, calendar: Calendar) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    public static func dayClock(_ date: Date, calendar: Calendar) -> String {
        formatter("EEE HH:mm", calendar: calendar).string(from: date)
    }

    public static func resetText(for limit: UsageLimit, now: Date, calendar: Calendar) -> String {
        guard let resetsAt = limit.resetsAt else {
            return limit.kind == "session" ? "no active session" : "not started"
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "resetting…" }
        if remaining < 86_400 { return "resets \(clock(resetsAt, calendar: calendar)) (in \(duration(remaining)))" }
        return "resets \(dayClock(resetsAt, calendar: calendar))"
    }

    public static func paceLine(_ pace: Pace, percent: Double, calendar: Calendar) -> String {
        if percent >= 100 { return "limit reached" }
        switch pace.status {
        case .unknown: return ""
        case .onPace: return "on pace"
        case .under(let points): return "\(points) pts under pace"
        case .ahead(let points, let hit):
            guard let hit else { return "ahead of pace +\(points) pts" }
            return "ahead of pace +\(points) pts · 100% ≈ \(dayClock(hit, calendar: calendar))"
        }
    }

    public static func updatedAgo(_ date: Date?, now: Date) -> String {
        guard let date else { return "not updated yet" }
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? "updated just now" : "updated \(duration(seconds)) ago"
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "PaceTests|RecommenderTests|FormatTests"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): pace projection, account recommender and text formatting"
```

---

### Task 5: Pricing and cost

**Files:**
- Create: `Sources/UsageCore/Pricing.swift`, `Sources/UsageCore/PricingData.swift`
- Test: `Tests/UsageCoreTests/PricingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct ModelPrice: Codable, Sendable, Equatable { prefix: String; input: Double; output: Double; cacheRead: Double }` ($/MTok).
  - `public struct PricingTable: Codable, Sendable, Equatable` — `models: [ModelPrice]`, `plans: [String: Double]` (monthly USD by plan name, e.g. `"Max 20x": 200`); `static let builtin`; `static func load(override url: URL?) -> PricingTable`; `func price(for modelID: String) -> ModelPrice?` (longest prefix); `func monthlyTotal(for plans: [String]) -> Double`; constants `cacheWrite5mMultiplier = 1.25`, `cacheWrite1hMultiplier = 2.0`, `fastModeMultiplier = 2.0`.
  - `public struct TokenUsage: Sendable, Equatable` — `input`, `output`, `cacheRead`, `cacheWrite5m`, `cacheWrite1h: Int64`, `isFast: Bool`; `public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0, isFast: Bool = false)`; `var totalTokens: Int64`.
  - `public enum CostCalculator { static func costMicros(_ usage: TokenUsage, modelID: String, table: PricingTable) -> Int64? }` (nil = unknown model).
  - `public enum ModelNames { static func family(_ modelID: String) -> String? }` → "Fable", "Opus", "Sonnet", "Haiku", "Mythos".

- [ ] **Step 1: Write the failing tests**

`Tests/UsageCoreTests/PricingTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct PricingTests {
    let table = PricingTable.builtin

    @Test func builtinMatchesSpecTable() {
        #expect(table.price(for: "claude-fable-5-1") == ModelPrice(prefix: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25))
        #expect(table.price(for: "claude-fable-5")?.cacheRead == 1.00)
        #expect(table.price(for: "claude-opus-5-5") == ModelPrice(prefix: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.20))
        #expect(table.price(for: "claude-opus-5")?.input == 5)
        #expect(table.price(for: "claude-opus-4-8")?.cacheRead == 0.50)
        #expect(table.price(for: "claude-sonnet-5-5")?.output == 10)
        #expect(table.price(for: "claude-sonnet-4-6")?.input == 3)
        #expect(table.price(for: "claude-haiku-4-5")?.cacheRead == 0.10)
    }

    @Test func pricesSuffixedModelIDs() {
        #expect(table.price(for: "claude-opus-5[1m]")?.prefix == "claude-opus-5")
        #expect(table.price(for: "claude-fable-5-1[1m]")?.prefix == "claude-fable-5-1")
        #expect(table.price(for: "claude-haiku-4-5-20251001")?.prefix == "claude-haiku-4-5")
        #expect(table.price(for: "gpt_image_2_5") == nil)
    }

    @Test func costOfRealFableMessage() {
        // usage from a real transcript line: 2 in, 3475 out, 25373 cache read, 35613 cache write (1h)
        let u = TokenUsage(input: 2, output: 3_475, cacheRead: 25_373, cacheWrite1h: 35_613)
        // 2×10 + 3475×50 + 25373×0.25 + 35613×10×2 = 892 373.25 µ$
        #expect(CostCalculator.costMicros(u, modelID: "claude-fable-5-1", table: table) == 892_373)
    }

    @Test func fiveMinuteWritesAndFastMode() {
        let u = TokenUsage(cacheWrite5m: 1_000)
        #expect(CostCalculator.costMicros(u, modelID: "claude-opus-5-5", table: table) == 5_000)   // 1000×4×1.25
        var fast = TokenUsage(output: 1_000)
        fast.isFast = true
        #expect(CostCalculator.costMicros(fast, modelID: "claude-opus-5-5", table: table) == 40_000) // 1000×20×2
    }

    @Test func unknownModelHasNoCost() {
        #expect(CostCalculator.costMicros(TokenUsage(output: 10), modelID: "mystery", table: table) == nil)
    }

    @Test func overrideFileWinsAndBadFileFallsBack() throws {
        let dir = try TempDir()
        let good = dir.file("pricing.json")
        try Data(#"{"models":[{"prefix":"x","input":1,"output":2,"cacheRead":0.1}],"plans":{"Pro":20}}"#.utf8).write(to: good)
        #expect(PricingTable.load(override: good).models.map(\.prefix) == ["x"])
        let bad = dir.file("bad.json")
        try Data("nope".utf8).write(to: bad)
        #expect(PricingTable.load(override: bad) == PricingTable.builtin)
        #expect(PricingTable.load(override: dir.file("missing.json")) == PricingTable.builtin)
    }

    @Test func monthlyTotalSumsKnownPlans() {
        #expect(table.monthlyTotal(for: ["Max 20x", "Max 5x", "Pro", "Unknown"]) == 320)
    }

    @Test func families() {
        #expect(ModelNames.family("claude-fable-5-1") == "Fable")
        #expect(ModelNames.family("claude-opus-5[1m]") == "Opus")
        #expect(ModelNames.family("claude-haiku-4-5-20251001") == "Haiku")
        #expect(ModelNames.family("gpt_image_2_5") == nil)
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter PricingTests`
Expected: build errors — `cannot find 'PricingTable' in scope`.

- [ ] **Step 3: Implement**

`Sources/UsageCore/PricingData.swift`:

```swift
/// Bundled prices in $/MTok (spec §9). Embedded as source so the app bundle needs no resource bundle.
let builtinPricingJSON = #"""
{
  "models": [
    {"prefix": "claude-fable-5-1",  "input": 10.00, "output": 50.00, "cacheRead": 0.25},
    {"prefix": "claude-fable-5",    "input": 10.00, "output": 50.00, "cacheRead": 1.00},
    {"prefix": "claude-opus-5-5",   "input": 4.00,  "output": 20.00, "cacheRead": 0.20},
    {"prefix": "claude-opus-5",     "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-8",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-7",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-opus-4-6",   "input": 5.00,  "output": 25.00, "cacheRead": 0.50},
    {"prefix": "claude-sonnet-5-5", "input": 2.00,  "output": 10.00, "cacheRead": 0.20},
    {"prefix": "claude-sonnet-5",   "input": 2.00,  "output": 10.00, "cacheRead": 0.20},
    {"prefix": "claude-sonnet-4-6", "input": 3.00,  "output": 15.00, "cacheRead": 0.30},
    {"prefix": "claude-haiku-4-5",  "input": 1.00,  "output": 5.00,  "cacheRead": 0.10}
  ],
  "plans": {"Max 20x": 200, "Max 5x": 100, "Max": 100, "Pro": 20, "Team · Premium": 150, "Team": 30}
}
"""#
```

`Sources/UsageCore/Pricing.swift`:

```swift
import Foundation

public struct ModelPrice: Codable, Sendable, Equatable {
    public var prefix: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
}

public struct PricingTable: Codable, Sendable, Equatable {
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
    public static let fastModeMultiplier = 2.0

    public var models: [ModelPrice]
    public var plans: [String: Double]

    public static let builtin: PricingTable = {
        do { return try JSONDecoder().decode(PricingTable.self, from: Data(builtinPricingJSON.utf8)) }
        catch { fatalError("builtin pricing JSON is invalid: \(error)") }
    }()

    /// The override file when it exists and decodes, the bundled table otherwise.
    public static func load(override url: URL?) -> PricingTable {
        guard let url, let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data) else { return builtin }
        return table
    }

    public func price(for modelID: String) -> ModelPrice? {
        models.filter { modelID.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
    }

    public func monthlyTotal(for plans: [String]) -> Double {
        plans.compactMap { self.plans[$0] }.reduce(0, +)
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var isFast: Bool

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0,
                cacheWrite1h: Int64 = 0, isFast: Bool = false) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.isFast = isFast
    }

    public var totalTokens: Int64 { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

public enum CostCalculator {
    /// Cost in micro-dollars (prices are $/MTok, so tokens × price = µ$). Nil when the model is unknown.
    public static func costMicros(_ usage: TokenUsage, modelID: String, table: PricingTable) -> Int64? {
        guard let p = table.price(for: modelID) else { return nil }
        var micros = Double(usage.input) * p.input
            + Double(usage.output) * p.output
            + Double(usage.cacheRead) * p.cacheRead
            + Double(usage.cacheWrite5m) * p.input * PricingTable.cacheWrite5mMultiplier
            + Double(usage.cacheWrite1h) * p.input * PricingTable.cacheWrite1hMultiplier
        if usage.isFast { micros *= PricingTable.fastModeMultiplier }
        return Int64(micros.rounded())
    }
}

public enum ModelNames {
    public static func family(_ modelID: String) -> String? {
        let id = modelID.lowercased()
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where id.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PricingTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): pricing table and API-equivalent cost calculator"
```

---

### Task 6: Incremental transcript index

**Files:**
- Create: `Sources/UsageCore/SQLite.swift`, `Sources/UsageCore/TranscriptParser.swift`, `Sources/UsageCore/TranscriptIndex.swift`
- Create: `Tests/UsageCoreTests/Support/TranscriptFixture.swift`
- Test: `Tests/UsageCoreTests/TranscriptIndexTests.swift`

**Interfaces:**
- Consumes: `ISODate` (Task 3), `TokenUsage`, `CostCalculator`, `PricingTable` (Task 5).
- Produces:
  - `public struct IndexProgress: Sendable, Equatable { var filesDone: Int; var filesTotal: Int; var isComplete: Bool }`.
  - `public struct IndexTotals: Sendable, Equatable { var messages: Int; var costMicros: Int64 }`.
  - `public actor TranscriptIndex` — `public init(databaseURL: URL, projectsDir: URL, pricing: PricingTable) throws`; `@discardableResult public func refresh(limit: Int? = nil, progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> IndexProgress` (with `limit`, stops after that many *changed* files and returns `isComplete == false`); `public func totals() throws -> IndexTotals`; `public func unknownModels() throws -> [String]`; `public func reset() throws`. Internal for Task 7: `let db: SQLiteDatabase`.
  - Internal SQLite wrapper: `final class SQLiteDatabase` (`init(url:)`, `exec(_:)`, `prepare(_:) -> Statement`, `transaction(_:)`, `var changes: Int32`), `final class Statement` (`run(_ values: [SQLValue])`, `rows(_ values: [SQLValue]) -> [[SQLValue]]`), `enum SQLValue { case int(Int64), double(Double), text(String), null; intValue; doubleValue; textValue }`.
  - Internal parser: `struct ParsedMessage { messageID, model, timestamp: Date, project, sessionID: String?, usage: TokenUsage }`, `enum TranscriptParser { static func parse(line: Data) -> ParsedMessage?; static func projectName(cwd: String?) -> String }`.
  - Test helper `enum TranscriptFixture { static func assistant(id: String, model: String = "claude-fable-5-1", timestamp: String = "2026-10-01T15:27:38.176Z", cwd: String = "/Users/dev/code/acme/app", session: String = "s1", input: Int = 2, output: Int = 3475, cacheRead: Int = 25373, cw5m: Int = 0, cw1h: Int = 35613, speed: String = "standard") -> String; static let user: String; static func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws; static func append(_ text: String, to url: URL) throws }`.

- [ ] **Step 1: Add the fixture builder**

`Tests/UsageCoreTests/Support/TranscriptFixture.swift`:

```swift
import Foundation

enum TranscriptFixture {
    /// One assistant line shaped like Claude Code's transcripts. Defaults = a real Fable 5.1 message (892 373 µ$).
    static func assistant(id: String, model: String = "claude-fable-5-1",
                          timestamp: String = "2026-10-01T15:27:38.176Z",
                          cwd: String = "/Users/dev/code/acme/app", session: String = "s1",
                          input: Int = 2, output: Int = 3475, cacheRead: Int = 25373,
                          cw5m: Int = 0, cw1h: Int = 35613, speed: String = "standard") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","cwd":"\#(cwd)","sessionId":"\#(session)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cw5m + cw1h),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":\#(cw5m),"ephemeral_1h_input_tokens":\#(cw1h)},"speed":"\#(speed)"}}}"#
    }

    static let user = #"{"type":"user","timestamp":"2026-10-01T15:27:30.000Z","message":{"role":"user","content":"hi"}}"#

    static func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try Data(text.utf8).write(to: url)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/TranscriptIndexTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct TranscriptIndexTests {
    let dir: TempDir
    let projects: URL
    let index: TranscriptIndex

    init() throws {
        dir = try TempDir()
        projects = dir.url.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        index = try TranscriptIndex(databaseURL: dir.file("index.sqlite"), projectsDir: projects, pricing: .builtin)
    }

    func file(_ relative: String) -> URL { projects.appendingPathComponent(relative) }

    @Test func parserReadsUsageAndProject() throws {
        let m = try #require(TranscriptParser.parse(line: Data(TranscriptFixture.assistant(id: "m1").utf8)))
        #expect(m.messageID == "m1")
        #expect(m.project == "acme/app")
        #expect(m.usage == TokenUsage(input: 2, output: 3_475, cacheRead: 25_373, cacheWrite5m: 0, cacheWrite1h: 35_613))
        #expect(TranscriptParser.parse(line: Data(TranscriptFixture.user.utf8)) == nil)
        #expect(TranscriptParser.projectName(cwd: nil) == "unknown")
        #expect(TranscriptParser.projectName(cwd: "/tmp") == "tmp")
    }

    @Test func duplicatesAreCountedOnce() async throws {
        let line = TranscriptFixture.assistant(id: "m1")
        try TranscriptFixture.write([TranscriptFixture.user, line, line, line, line], to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 1, costMicros: 892_373))
    }

    @Test func partialLastLineIsCountedOnceWhenCompleted() async throws {
        let first = TranscriptFixture.assistant(id: "m1")
        let second = TranscriptFixture.assistant(id: "m2")
        let half = second.index(second.startIndex, offsetBy: second.count / 2)
        try TranscriptFixture.write([first], to: file("p/s1.jsonl"))
        try TranscriptFixture.append(String(second[..<half]), to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals().messages == 1)

        try TranscriptFixture.append(String(second[half...]) + "\n", to: file("p/s1.jsonl"))
        try await index.refresh()
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 2, costMicros: 2 * 892_373))
    }

    @Test func truncatedFileDoesNotDoubleCount() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1"), TranscriptFixture.assistant(id: "m2")],
                                    to: file("p/s1.jsonl"))
        try await index.refresh()
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals().messages == 2)
    }

    @Test func subagentFilesAreIncluded() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "sub1")], to: file("p/s1/subagents/agent-1.jsonl"))
        let progress = try await index.refresh()
        #expect(progress == IndexProgress(filesDone: 2, filesTotal: 2))
        #expect(try await index.totals().messages == 2)
    }

    @Test func unknownModelIsListedAndCostsZero() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "x1", model: "gpt_image_2_5"),
                                     TranscriptFixture.assistant(id: "s1", model: "<synthetic>")],
                                    to: file("p/s1.jsonl"))
        try await index.refresh()
        #expect(try await index.totals() == IndexTotals(messages: 1, costMicros: 0))
        #expect(try await index.unknownModels() == ["gpt_image_2_5"])
    }

    @Test func limitedRefreshReportsPartialProgress() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "a")], to: file("p/a.jsonl"))
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "b")], to: file("p/b.jsonl"))
        let first = try await index.refresh(limit: 1)
        #expect(first == IndexProgress(filesDone: 1, filesTotal: 2))
        #expect(first.isComplete == false)
        #expect(try await index.totals().messages == 1)
        let second = try await index.refresh()
        #expect(second.isComplete)
        #expect(try await index.totals().messages == 2)
    }

    @Test func survivesReopenAndReset() async throws {
        try TranscriptFixture.write([TranscriptFixture.assistant(id: "m1")], to: file("p/s1.jsonl"))
        try await index.refresh()
        let reopened = try TranscriptIndex(databaseURL: dir.file("index.sqlite"), projectsDir: projects, pricing: .builtin)
        try await reopened.refresh()
        #expect(try await reopened.totals().messages == 1)
        try await reopened.reset()
        #expect(try await reopened.totals().messages == 0)
        try await reopened.refresh()
        #expect(try await reopened.totals().messages == 1)
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter TranscriptIndexTests`
Expected: build errors — `cannot find 'TranscriptIndex' in scope`.

- [ ] **Step 4: Implement the SQLite wrapper**

`Sources/UsageCore/SQLite.swift`:

```swift
import Foundation
import SQLite3

enum SQLiteError: Error, Equatable {
    case open(String), prepare(String), step(String), exec(String)
}

enum SQLValue: Equatable, Sendable {
    case int(Int64), double(Double), text(String), null

    var intValue: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return 0
        }
    }

    var doubleValue: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return 0
        }
    }

    var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }
}

private var sqliteTransient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

/// Minimal wrapper over the system SQLite. Not thread-safe: owned by one actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError.open(String(cString: sqlite3_errmsg(handle)))
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close_v2(handle) }

    var message: String { String(cString: sqlite3_errmsg(handle)) }
    var changes: Int32 { sqlite3_changes(handle) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? message
            sqlite3_free(error)
            throw SQLiteError.exec(text)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(message)
        }
        return Statement(stmt: stmt, db: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    private let stmt: OpaquePointer
    private unowned let db: SQLiteDatabase

    init(stmt: OpaquePointer, db: SQLiteDatabase) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    private func bind(_ values: [SQLValue]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, sqliteTransient)
            case .null: sqlite3_bind_null(stmt, i)
            }
        }
    }

    func run(_ values: [SQLValue] = []) throws {
        bind(values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(db.message) }
    }

    func rows(_ values: [SQLValue] = []) throws -> [[SQLValue]] {
        bind(values)
        var out: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError.step(db.message) }
            out.append((0..<sqlite3_column_count(stmt)).map { column in
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, column))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, column))
                case SQLITE_TEXT:
                    guard let text = sqlite3_column_text(stmt, column) else { return .null }
                    return .text(String(cString: text))
                default: return .null
                }
            })
        }
        return out
    }
}
```

- [ ] **Step 5: Implement the parser**

`Sources/UsageCore/TranscriptParser.swift`:

```swift
import Foundation

struct ParsedMessage: Equatable {
    let messageID: String
    let model: String
    let timestamp: Date
    let project: String
    let sessionID: String?
    let usage: TokenUsage
}

enum TranscriptParser {
    static let assistantMarker = Data(#""type":"assistant""#.utf8)

    private struct RawLine: Decodable {
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }
        struct Usage: Decodable {
            struct CacheCreation: Decodable {
                let ephemeral_5m_input_tokens: Int64?
                let ephemeral_1h_input_tokens: Int64?
            }
            let input_tokens: Int64?
            let output_tokens: Int64?
            let cache_read_input_tokens: Int64?
            let cache_creation_input_tokens: Int64?
            let cache_creation: CacheCreation?
            let speed: String?
        }
        let type: String
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let message: Message?
    }

    /// Nil for anything that isn't a billable assistant message.
    static func parse(line: Data) -> ParsedMessage? {
        guard line.range(of: assistantMarker) != nil,
              let raw = try? JSONDecoder().decode(RawLine.self, from: line),
              raw.type == "assistant",
              let message = raw.message, let id = message.id, let model = message.model, model != "<synthetic>",
              let usage = message.usage,
              let timestamp = raw.timestamp.flatMap(ISODate.parse) else { return nil }

        let cw5m: Int64
        let cw1h: Int64
        if let detail = usage.cache_creation {
            cw5m = detail.ephemeral_5m_input_tokens ?? 0
            cw1h = detail.ephemeral_1h_input_tokens ?? 0
        } else {
            cw5m = usage.cache_creation_input_tokens ?? 0
            cw1h = 0
        }
        return ParsedMessage(
            messageID: id, model: model, timestamp: timestamp, project: projectName(cwd: raw.cwd),
            sessionID: raw.sessionId,
            usage: TokenUsage(input: usage.input_tokens ?? 0, output: usage.output_tokens ?? 0,
                              cacheRead: usage.cache_read_input_tokens ?? 0, cacheWrite5m: cw5m,
                              cacheWrite1h: cw1h, isFast: usage.speed == "fast"))
    }

    /// Last two path components of the working directory ("acme/app").
    static func projectName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        let parts = cwd.split(separator: "/").map(String.init)
        return parts.isEmpty ? "unknown" : parts.suffix(2).joined(separator: "/")
    }
}
```

- [ ] **Step 6: Implement the index**

`Sources/UsageCore/TranscriptIndex.swift`:

```swift
import Foundation

public struct IndexProgress: Sendable, Equatable {
    public var filesDone: Int
    public var filesTotal: Int
    public var isComplete: Bool { filesDone == filesTotal }

    public init(filesDone: Int, filesTotal: Int) {
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }
}

public struct IndexTotals: Sendable, Equatable {
    public var messages: Int
    public var costMicros: Int64
}

/// Incremental index of ~/.claude/projects/**/*.jsonl into hourly cost buckets (spec §9).
public actor TranscriptIndex {
    let db: SQLiteDatabase
    private let projectsDir: URL
    private let pricing: PricingTable
    private let selectFile: Statement
    private let upsertFile: Statement
    private let insertSeen: Statement
    private let upsertBucket: Statement
    private let insertSession: Statement
    private let insertUnknown: Statement

    static let schema = """
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime REAL NOT NULL,
                                         offset INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS seen(message_id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS buckets(hour INTEGER NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
            cw5m INTEGER NOT NULL DEFAULT 0, cw1h INTEGER NOT NULL DEFAULT 0, cost_micros INTEGER NOT NULL DEFAULT 0,
            messages INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(hour, model, project));
        CREATE TABLE IF NOT EXISTS sessions(hour INTEGER NOT NULL, session_id TEXT NOT NULL,
                                            PRIMARY KEY(hour, session_id)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS unknown_models(model TEXT PRIMARY KEY) WITHOUT ROWID;
        """

    public init(databaseURL: URL, projectsDir: URL, pricing: PricingTable) throws {
        let db = try SQLiteDatabase(url: databaseURL)
        try db.exec(Self.schema)
        self.db = db
        self.projectsDir = projectsDir
        self.pricing = pricing
        selectFile = try db.prepare("SELECT size, mtime, offset FROM files WHERE path = ?")
        upsertFile = try db.prepare("""
            INSERT INTO files(path, size, mtime, offset) VALUES(?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, offset = excluded.offset
            """)
        insertSeen = try db.prepare("INSERT OR IGNORE INTO seen(message_id) VALUES(?)")
        upsertBucket = try db.prepare("""
            INSERT INTO buckets(hour, model, project, input, output, cache_read, cw5m, cw1h, cost_micros, messages)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(hour, model, project) DO UPDATE SET
              input = input + excluded.input, output = output + excluded.output,
              cache_read = cache_read + excluded.cache_read, cw5m = cw5m + excluded.cw5m, cw1h = cw1h + excluded.cw1h,
              cost_micros = cost_micros + excluded.cost_micros, messages = messages + 1
            """)
        insertSession = try db.prepare("INSERT OR IGNORE INTO sessions(hour, session_id) VALUES(?, ?)")
        insertUnknown = try db.prepare("INSERT OR IGNORE INTO unknown_models(model) VALUES(?)")
    }

    /// Indexes new bytes of every transcript. With `limit`, stops after that many changed files so callers can
    /// show partial totals during the first (multi-GB) run.
    @discardableResult
    public func refresh(limit: Int? = nil, progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> IndexProgress {
        let files = Self.transcriptFiles(in: projectsDir)
        var processed = 0
        for (offset, url) in files.enumerated() {
            if try indexFile(url) { processed += 1 }
            let done = IndexProgress(filesDone: offset + 1, filesTotal: files.count)
            if (offset + 1) % 25 == 0 { progress?(done) }
            if let limit, processed >= limit, !done.isComplete {
                progress?(done)
                return done
            }
        }
        let done = IndexProgress(filesDone: files.count, filesTotal: files.count)
        progress?(done)
        return done
    }

    public func totals() throws -> IndexTotals {
        let row = try db.prepare("SELECT COALESCE(SUM(messages), 0), COALESCE(SUM(cost_micros), 0) FROM buckets").rows()[0]
        return IndexTotals(messages: Int(row[0].intValue), costMicros: row[1].intValue)
    }

    public func unknownModels() throws -> [String] {
        try db.prepare("SELECT model FROM unknown_models ORDER BY model").rows().compactMap { $0[0].textValue }
    }

    /// Forgets everything (used by `claude-usage-cli reindex` after editing pricing.json).
    public func reset() throws {
        try db.exec("DELETE FROM files; DELETE FROM seen; DELETE FROM buckets; DELETE FROM sessions; DELETE FROM unknown_models;")
    }

    static func transcriptFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" { out.append(url) }
        return out.sorted { $0.path < $1.path }
    }

    /// Returns true when the file had changed and was (re)read.
    private func indexFile(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stored = try selectFile.rows([.text(url.path)]).first
        if let stored, stored[0].intValue == size, stored[1].doubleValue == mtime { return false }

        var offset = stored?[2].intValue ?? 0
        if offset > size { offset = 0 }   // truncated or rewritten: re-read; `seen` prevents double counting

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        try db.transaction {
            var pending = Data()
            var consumed = offset
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    if let message = TranscriptParser.parse(line: Data(pending[lineStart..<newline])) {
                        try ingest(message)
                    }
                    consumed += Int64(newline - lineStart + 1)
                    lineStart = newline + 1
                }
                pending = Data(pending[lineStart...])   // keep the unfinished last line for later
            }
            try upsertFile.run([.text(url.path), .int(size), .double(mtime), .int(consumed)])
        }
        return true
    }

    private func ingest(_ m: ParsedMessage) throws {
        try insertSeen.run([.text(m.messageID)])
        guard db.changes > 0 else { return }   // already counted (streamed duplicates, resumed sessions)
        let hour = Int64((m.timestamp.timeIntervalSince1970 / 3_600).rounded(.down)) * 3_600
        let cost = CostCalculator.costMicros(m.usage, modelID: m.model, table: pricing)
        if cost == nil { try insertUnknown.run([.text(m.model)]) }
        try upsertBucket.run([.int(hour), .text(m.model), .text(m.project), .int(m.usage.input), .int(m.usage.output),
                              .int(m.usage.cacheRead), .int(m.usage.cacheWrite5m), .int(m.usage.cacheWrite1h),
                              .int(cost ?? 0)])
        if let session = m.sessionID { try insertSession.run([.int(hour), .text(session)]) }
    }
}
```

Note: the unknown model `gpt_image_2_5` is counted as a message with $0 (it is a real assistant turn); `<synthetic>` lines are not counted at all.

- [ ] **Step 7: Run tests**

Run: `swift test --filter TranscriptIndexTests`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): incremental SQLite index of Claude Code transcripts"
```

---

### Task 7: Spend statistics

**Files:**
- Create: `Sources/UsageCore/Stats.swift`
- Test: `Tests/UsageCoreTests/StatsTests.swift`

**Interfaces:**
- Consumes: `TranscriptIndex` + its internal `db`/`SQLValue` (Task 6), `ModelNames` (Task 5), `TranscriptFixture` (Task 6 test support).
- Produces:
  - `public struct HourCost: Sendable, Equatable { hourStart: Date; costMicros: Int64 }`, `public struct ModelShare: Sendable, Equatable { family: String; costMicros: Int64; fraction: Double }`, `public struct ProjectCost: Sendable, Equatable { project: String; costMicros: Int64 }`.
  - `public struct SpendStats: Sendable, Equatable` — `todayMicros`, `last7dMicros`, `last30dMicros: Int64`, `todayTokens: Int64`, `cacheHitRate: Double`, `todayMessages: Int`, `todaySessions: Int`, `hourly: [HourCost]` (24, oldest first, zero-filled), `modelMix: [ModelShare]` (today, by cost desc), `topProjects: [ProjectCost]` (today, top 3); `static let empty`.
  - `extension TranscriptIndex { public func stats(now: Date, calendar: Calendar) throws -> SpendStats; public func topModelFamily(since: Date) throws -> String? }`. Windows: today = `calendar.startOfDay(now)`; 7 days = today − 6 days; 30 days = today − 29 days.

- [ ] **Step 1: Write the failing tests**

`Tests/UsageCoreTests/StatsTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct StatsTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_790_886_600)   // 2026-10-01 20:30 UTC

    func makeIndex() async throws -> (TempDir, TranscriptIndex) {
        let dir = try TempDir()
        let projects = dir.url.appendingPathComponent("projects", isDirectory: true)
        try TranscriptFixture.write([
            TranscriptFixture.assistant(id: "today-fable"),   // 15:27 UTC, 892 373 µ$, acme/app, s1
            TranscriptFixture.assistant(id: "today-opus", model: "claude-opus-5-5", timestamp: "2026-10-01T18:05:00Z",
                                        cwd: "/Users/dev/code/side-project", session: "s2",
                                        input: 1_000, output: 2_000, cacheRead: 0, cw5m: 0, cw1h: 0),  // 44 000 µ$
            TranscriptFixture.assistant(id: "3d-haiku", model: "claude-haiku-4-5-20251001",
                                        timestamp: "2026-09-28T10:00:00Z", session: "s3",
                                        input: 1_000_000, output: 0, cacheRead: 0, cw5m: 0, cw1h: 0), // 1 000 000 µ$
            TranscriptFixture.assistant(id: "20d-sonnet", model: "claude-sonnet-5", timestamp: "2026-09-11T10:00:00Z",
                                        session: "s4", input: 0, output: 100_000, cacheRead: 0, cw5m: 0, cw1h: 0), // 1 000 000 µ$
            TranscriptFixture.assistant(id: "40d-fable", timestamp: "2026-08-22T10:00:00Z", session: "s5",
                                        input: 0, output: 1_000, cacheRead: 0, cw5m: 0, cw1h: 0),       // excluded
        ], to: projects.appendingPathComponent("p/s.jsonl"))
        let index = try TranscriptIndex(databaseURL: dir.file("i.sqlite"), projectsDir: projects, pricing: .builtin)
        try await index.refresh()
        return (dir, index)
    }

    @Test func windowsAndToday() async throws {
        let (_, index) = try await makeIndex()
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.todayMicros == 936_373)
        #expect(s.last7dMicros == 1_936_373)
        #expect(s.last30dMicros == 2_936_373)
        #expect(s.todayMessages == 2)
        #expect(s.todaySessions == 2)
        #expect(s.todayTokens == 67_463)
        #expect(abs(s.cacheHitRate - 25_373.0 / 61_988.0) < 1e-9)
    }

    @Test func hourlyIsLast24HoursZeroFilled() async throws {
        let (_, index) = try await makeIndex()
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.hourly.count == 24)
        #expect(s.hourly.last?.hourStart == Date(timeIntervalSince1970: 1_790_884_800))   // 20:00
        #expect(s.hourly.first?.hourStart == Date(timeIntervalSince1970: 1_790_884_800 - 23 * 3_600))
        #expect(s.hourly.first { $0.hourStart == Date(timeIntervalSince1970: 1_790_866_800) }?.costMicros == 892_373)
        #expect(s.hourly.first { $0.hourStart == Date(timeIntervalSince1970: 1_790_877_600) }?.costMicros == 44_000)
        #expect(s.hourly.map(\.costMicros).reduce(0, +) == 936_373)
    }

    @Test func modelMixAndTopProjects() async throws {
        let (_, index) = try await makeIndex()
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.modelMix.map(\.family) == ["Fable", "Opus"])
        #expect(abs(s.modelMix[0].fraction - 892_373.0 / 936_373.0) < 1e-9)
        #expect(s.topProjects == [ProjectCost(project: "acme/app", costMicros: 892_373),
                                  ProjectCost(project: "code/side-project", costMicros: 44_000)])
    }

    @Test func topModelFamilySince() async throws {
        let (_, index) = try await makeIndex()
        // Last 7 days: Haiku 1 000 000 µ$ beats Fable 892 373 µ$; today alone: Fable.
        #expect(try await index.topModelFamily(since: now.addingTimeInterval(-7 * 86_400)) == "Haiku")
        #expect(try await index.topModelFamily(since: Date(timeIntervalSince1970: 1_790_812_800)) == "Fable")
        #expect(try await index.topModelFamily(since: now.addingTimeInterval(3_600)) == nil)
    }

    @Test func emptyIndexGivesEmptyStats() async throws {
        let dir = try TempDir()
        let index = try TranscriptIndex(databaseURL: dir.file("i.sqlite"), projectsDir: dir.url, pricing: .builtin)
        let s = try await index.stats(now: now, calendar: utc)
        #expect(s.todayMicros == 0)
        #expect(s.cacheHitRate == 0)
        #expect(s.hourly.count == 24)
        #expect(s.modelMix.isEmpty)
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter StatsTests`
Expected: build errors — `value of type 'TranscriptIndex' has no member 'stats'`.

- [ ] **Step 3: Implement**

`Sources/UsageCore/Stats.swift`:

```swift
import Foundation

public struct HourCost: Sendable, Equatable {
    public var hourStart: Date
    public var costMicros: Int64
}

public struct ModelShare: Sendable, Equatable {
    public var family: String
    public var costMicros: Int64
    public var fraction: Double
}

public struct ProjectCost: Sendable, Equatable {
    public var project: String
    public var costMicros: Int64
}

public struct SpendStats: Sendable, Equatable {
    public var todayMicros: Int64
    public var last7dMicros: Int64
    public var last30dMicros: Int64
    public var todayTokens: Int64
    public var cacheHitRate: Double
    public var todayMessages: Int
    public var todaySessions: Int
    public var hourly: [HourCost]
    public var modelMix: [ModelShare]
    public var topProjects: [ProjectCost]

    public static let empty = SpendStats(todayMicros: 0, last7dMicros: 0, last30dMicros: 0, todayTokens: 0,
                                         cacheHitRate: 0, todayMessages: 0, todaySessions: 0, hourly: [],
                                         modelMix: [], topProjects: [])
}

extension TranscriptIndex {
    public func stats(now: Date, calendar: Calendar) throws -> SpendStats {
        let today = calendar.startOfDay(for: now)
        let day7 = calendar.date(byAdding: .day, value: -6, to: today)!
        let day30 = calendar.date(byAdding: .day, value: -29, to: today)!
        let t = Int64(today.timeIntervalSince1970)

        func sumCost(since: Date) throws -> Int64 {
            try db.prepare("SELECT COALESCE(SUM(cost_micros), 0) FROM buckets WHERE hour >= ?")
                .rows([.int(Int64(since.timeIntervalSince1970))])[0][0].intValue
        }

        let tokenRow = try db.prepare("""
            SELECT COALESCE(SUM(input), 0), COALESCE(SUM(output), 0), COALESCE(SUM(cache_read), 0),
                   COALESCE(SUM(cw5m), 0), COALESCE(SUM(cw1h), 0), COALESCE(SUM(messages), 0)
            FROM buckets WHERE hour >= ?
            """).rows([.int(t)])[0]
        let input = tokenRow[0].intValue, output = tokenRow[1].intValue, cacheRead = tokenRow[2].intValue
        let writes = tokenRow[3].intValue + tokenRow[4].intValue
        let promptSide = input + cacheRead + writes

        let sessions = try db.prepare("SELECT COUNT(DISTINCT session_id) FROM sessions WHERE hour >= ?")
            .rows([.int(t)])[0][0].intValue

        let currentHour = Int64((now.timeIntervalSince1970 / 3_600).rounded(.down)) * 3_600
        let firstHour = currentHour - 23 * 3_600
        var byHour: [Int64: Int64] = [:]
        for row in try db.prepare("SELECT hour, SUM(cost_micros) FROM buckets WHERE hour >= ? GROUP BY hour")
            .rows([.int(firstHour)]) {
            byHour[row[0].intValue] = row[1].intValue
        }
        let hourly = (0..<24).map { i -> HourCost in
            let hour = firstHour + Int64(i) * 3_600
            return HourCost(hourStart: Date(timeIntervalSince1970: TimeInterval(hour)), costMicros: byHour[hour] ?? 0)
        }

        var byFamily: [String: Int64] = [:]
        for row in try db.prepare("SELECT model, SUM(cost_micros) FROM buckets WHERE hour >= ? GROUP BY model")
            .rows([.int(t)]) {
            let model = row[0].textValue ?? "unknown"
            byFamily[ModelNames.family(model) ?? model, default: 0] += row[1].intValue
        }
        let todayCost = byFamily.values.reduce(0, +)
        let mix = byFamily.filter { $0.value > 0 }
            .map { ModelShare(family: $0.key, costMicros: $0.value,
                              fraction: todayCost > 0 ? Double($0.value) / Double(todayCost) : 0) }
            .sorted { ($0.costMicros, $1.family) > ($1.costMicros, $0.family) }

        let projects = try db.prepare("""
            SELECT project, SUM(cost_micros) AS c FROM buckets WHERE hour >= ?
            GROUP BY project HAVING c > 0 ORDER BY c DESC, project ASC LIMIT 3
            """).rows([.int(t)]).map { ProjectCost(project: $0[0].textValue ?? "unknown", costMicros: $0[1].intValue) }

        return SpendStats(todayMicros: try sumCost(since: today), last7dMicros: try sumCost(since: day7),
                          last30dMicros: try sumCost(since: day30), todayTokens: promptSide + output,
                          cacheHitRate: promptSide > 0 ? Double(cacheRead) / Double(promptSide) : 0,
                          todayMessages: Int(tokenRow[5].intValue), todaySessions: Int(sessions),
                          hourly: hourly, modelMix: mix, topProjects: projects)
    }

    /// The model family with the highest cost since `since` ("Fable"), used to pick the relevant weekly limit.
    public func topModelFamily(since: Date) throws -> String? {
        var byFamily: [String: Int64] = [:]
        for row in try db.prepare("SELECT model, SUM(cost_micros) FROM buckets WHERE hour >= ? GROUP BY model")
            .rows([.int(Int64(since.timeIntervalSince1970))]) {
            guard let family = row[0].textValue.flatMap(ModelNames.family) else { continue }
            byFamily[family, default: 0] += row[1].intValue
        }
        return byFamily.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter StatsTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): spend statistics (today/7d/30d, hourly, model mix, top projects)"
```

---

### Task 8: Accounts store and the terminal account file

**Files:**
- Create: `Sources/UsageCore/Accounts.swift`, `Sources/UsageCore/TerminalAccount.swift`
- Create: `Tests/UsageCoreTests/Support/AccountFactory.swift`
- Test: `Tests/UsageCoreTests/AccountsTests.swift`, `Tests/UsageCoreTests/TerminalAccountTests.swift`

**Interfaces:**
- Consumes: `SecretStore`, `OAuthCredentials` (Task 2), `NSLock.locked` (Task 1).
- Produces:
  - `public enum AccountStatus: String, Codable, Sendable { case ok, needsSignIn, offline, rateLimited }`.
  - `public struct Account: Codable, Sendable, Equatable, Identifiable` — `id`, `accountUuid`, `organizationUuid`, `email: String`; `displayName`, `organizationName`, `organizationType`, `rateLimitTier`, `subscriptionType: String?`; `label: String`; `colorIndex: Int`; `addedAt: Date`; `status: AccountStatus`; `oauthAccountJSON: Data?` (raw `oauthAccount` object for this account). Computed `plan: String`. `static func makeID(accountUuid:organizationUuid:) -> String`; `static func defaultLabel(email: String, organizationName: String?) -> String`; `func oauthAccountPayload() throws -> Data` (oauthAccountJSON, or one synthesized from the fields).
  - `public enum PlanName { static func from(subscriptionType: String?, rateLimitTier: String?, organizationType: String?) -> String }`.
  - `public final class AccountStore: @unchecked Sendable` — `static let keychainService = "Claude Usage"`, `static let paletteSize = 6`; `public init(fileURL: URL, secrets: any SecretStore)`; `load() throws -> [Account]`; `save(_:) throws`; `account(id:) throws -> Account?`; `@discardableResult upsert(_:) throws -> Account`; `update(id:_ mutate: (inout Account) -> Void) throws`; `remove(id:) throws` (also deletes its Keychain item); `credentials(for:) throws -> OAuthCredentials?`; `setCredentials(_:for:) throws`; `nextColorIndex() throws -> Int`.
  - `public struct TerminalIdentity: Sendable, Equatable { accountUuid, organizationUuid, email; var accountID: String }`.
  - `public enum TerminalAccountError: Error, Equatable { case notAnObject, lockTimeout, lockFailed(Int32), concurrentModification, renameFailed(Int32) }`.
  - `public struct TerminalAccountFile: Sendable` — `public init(url: URL)`; `readOAuthAccountJSON() throws -> Data?`; `currentIdentity() throws -> TerminalIdentity?` (nil when the file, the key, or the uuids are missing or the file isn't an object); `static func identity(fromOAuthAccountJSON: Data) -> TerminalIdentity?`; `replaceOAuthAccount(with json: Data, maxAttempts: Int = 5, lockTimeout: TimeInterval = 3, beforeSwap: (() throws -> Void)? = nil) throws`.
  - `public enum TerminalAccountImporter { @discardableResult static func importIfNeeded(store: AccountStore, terminal: TerminalAccountFile, now: Date) throws -> Account? }` — adds/refreshes the terminal's account (no credentials copied; they stay owned by Claude Code), keeping an existing label/color/addedAt.
  - Test helpers: `extension Account { static func fake(_ tag: String, email: String? = nil, label: String? = nil, status: AccountStatus = .ok) -> Account }` (id `"acc-<tag>:org-<tag>"`, `oauthAccountJSON` set); `enum ClaudeJSONFixture { static func oauthAccount(tag: String, email: String) -> String; static func file(tag: String, email: String) -> String }` (adds `numStartups: 7` and `mcpServers: {"linear": {"type": "http"}}`).

- [ ] **Step 1: Add test support**

`Tests/UsageCoreTests/Support/AccountFactory.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/AccountsTests.swift`:

```swift
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
}
```

`Tests/UsageCoreTests/TerminalAccountTests.swift`:

```swift
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
        try FileManager.default.createDirectory(at: dir.file(".claude.json.lock"), withIntermediateDirectories: false)
        #expect(throws: TerminalAccountError.lockTimeout) {
            try file.replaceOAuthAccount(with: Data("{}".utf8), lockTimeout: 0.2)
        }
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
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter "AccountsTests|TerminalAccountTests"`
Expected: build errors — `cannot find 'AccountStore' in scope`.

- [ ] **Step 4: Implement accounts**

`Sources/UsageCore/Accounts.swift`:

```swift
import Foundation

public enum AccountStatus: String, Codable, Sendable {
    case ok, needsSignIn, offline, rateLimited
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var accountUuid: String
    public var organizationUuid: String
    public var email: String
    public var displayName: String?
    public var organizationName: String?
    public var organizationType: String?
    public var rateLimitTier: String?
    public var subscriptionType: String?
    public var label: String
    public var colorIndex: Int
    public var addedAt: Date
    public var status: AccountStatus
    /// This account's raw `oauthAccount` object from a `.claude.json`, written back on "Use in terminal".
    public var oauthAccountJSON: Data?

    public var plan: String {
        PlanName.from(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier,
                      organizationType: organizationType)
    }

    public static func makeID(accountUuid: String, organizationUuid: String) -> String {
        "\(accountUuid):\(organizationUuid)"
    }

    static let publicMailDomains: Set<String> = ["gmail", "googlemail", "outlook", "hotmail", "live", "icloud", "me",
                                                 "yahoo", "proton", "protonmail", "aol"]

    /// Org name when it is a real name; else the email's company domain ("Work"); else the local part.
    public static func defaultLabel(email: String, organizationName: String?) -> String {
        if let org = organizationName, !org.isEmpty, !org.hasSuffix("'s Organization") { return org }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        let local = parts.first ?? email
        guard parts.count == 2, let domain = parts[1].split(separator: ".").first.map(String.init),
              !publicMailDomains.contains(domain.lowercased()) else { return local }
        return domain.prefix(1).uppercased() + domain.dropFirst()
    }

    public func oauthAccountPayload() throws -> Data {
        if let oauthAccountJSON { return oauthAccountJSON }
        var o: [String: Any] = ["accountUuid": accountUuid, "organizationUuid": organizationUuid, "emailAddress": email]
        if let displayName { o["displayName"] = displayName }
        if let organizationName { o["organizationName"] = organizationName }
        if let organizationType { o["organizationType"] = organizationType }
        if let rateLimitTier { o["organizationRateLimitTier"] = rateLimitTier }
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
}

public enum PlanName {
    public static func from(subscriptionType: String?, rateLimitTier: String?, organizationType: String?) -> String {
        let tier = (rateLimitTier ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        let kind = (subscriptionType ?? organizationType ?? "").lowercased()
        if kind.contains("max") { return "Max" }
        if kind.contains("pro") { return "Pro" }
        if kind.contains("team") { return tier.contains("premium") ? "Team · Premium" : "Team" }
        if kind.contains("enterprise") { return "Enterprise" }
        return "Claude"
    }
}

/// Account list in accounts.json; app-owned credentials in the Keychain (service "Claude Usage").
public final class AccountStore: @unchecked Sendable {
    public static let keychainService = "Claude Usage"
    public static let paletteSize = 6

    private let fileURL: URL
    private let secrets: any SecretStore
    private let lock = NSLock()

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public func load() throws -> [Account] { try lock.locked { try loadUnlocked() } }

    public func save(_ accounts: [Account]) throws { try lock.locked { try saveUnlocked(accounts) } }

    public func account(id: String) throws -> Account? { try load().first { $0.id == id } }

    @discardableResult
    public func upsert(_ account: Account) throws -> Account {
        try lock.locked {
            var all = try loadUnlocked()
            if let i = all.firstIndex(where: { $0.id == account.id }) { all[i] = account } else { all.append(account) }
            try saveUnlocked(all)
            return account
        }
    }

    public func update(id: String, _ mutate: (inout Account) -> Void) throws {
        try lock.locked {
            var all = try loadUnlocked()
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            mutate(&all[i])
            try saveUnlocked(all)
        }
    }

    public func remove(id: String) throws {
        try lock.locked {
            try saveUnlocked(try loadUnlocked().filter { $0.id != id })
        }
        try secrets.delete(service: Self.keychainService, account: id)
    }

    public func credentials(for id: String) throws -> OAuthCredentials? {
        guard let data = try secrets.read(service: Self.keychainService, account: id) else { return nil }
        return try JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    public func setCredentials(_ creds: OAuthCredentials, for id: String) throws {
        try secrets.write(service: Self.keychainService, account: id, data: JSONEncoder().encode(creds))
    }

    public func nextColorIndex() throws -> Int {
        let all = try load()
        let used = Set(all.map(\.colorIndex))
        return (0..<Self.paletteSize).first { !used.contains($0) } ?? all.count % Self.paletteSize
    }

    private func loadUnlocked() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Account].self, from: Data(contentsOf: fileURL))
    }

    private func saveUnlocked(_ accounts: [Account]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Implement the terminal account file**

`Sources/UsageCore/TerminalAccount.swift`:

```swift
import Foundation

public struct TerminalIdentity: Sendable, Equatable {
    public var accountUuid: String
    public var organizationUuid: String
    public var email: String
    public var accountID: String { Account.makeID(accountUuid: accountUuid, organizationUuid: organizationUuid) }
}

public enum TerminalAccountError: Error, Equatable {
    case notAnObject
    case lockTimeout
    case lockFailed(Int32)
    case concurrentModification
    case renameFailed(Int32)
}

/// Claude Code's lock convention: a `<file>.lock` directory, considered stale after 10 s.
struct DirectoryLock {
    let url: URL
    var staleAfter: TimeInterval = 10

    func acquire(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if mkdir(url.path, 0o755) == 0 { return }
            let error = errno
            guard error == EEXIST else { throw TerminalAccountError.lockFailed(error) }
            if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > staleAfter {
                rmdir(url.path)
                continue
            }
            if Date() >= deadline { throw TerminalAccountError.lockTimeout }
            usleep(50_000)
        }
    }

    func release() { rmdir(url.path) }
}

/// `~/.claude.json` — which account the terminal uses (`oauthAccount`). Other keys are never touched.
public struct TerminalAccountFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func readOAuthAccountJSON() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any] else { return nil }
        return try JSONSerialization.data(withJSONObject: oauth, options: [.sortedKeys])
    }

    public func currentIdentity() throws -> TerminalIdentity? {
        try readOAuthAccountJSON().flatMap(Self.identity(fromOAuthAccountJSON:))
    }

    public static func identity(fromOAuthAccountJSON data: Data) -> TerminalIdentity? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = o["accountUuid"] as? String, let org = o["organizationUuid"] as? String else { return nil }
        return TerminalIdentity(accountUuid: account, organizationUuid: org, email: o["emailAddress"] as? String ?? "")
    }

    /// Read-modify-write under Claude Code's lock; retries when the file changed between our read and our rename.
    public func replaceOAuthAccount(with json: Data, maxAttempts: Int = 5, lockTimeout: TimeInterval = 3,
                                    beforeSwap: (() throws -> Void)? = nil) throws {
        let replacement = try JSONSerialization.jsonObject(with: json)
        let lock = DirectoryLock(url: URL(fileURLWithPath: url.path + ".lock"))
        for _ in 0..<maxAttempts {
            try lock.acquire(timeout: lockTimeout)
            defer { lock.release() }

            let original = try Data(contentsOf: url)
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw TerminalAccountError.notAnObject
            }
            object["oauthAccount"] = replacement
            let output = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])

            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).claude-usage-\(UUID().uuidString)")
            try output.write(to: temp)
            if let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            }

            try beforeSwap?()
            guard try Data(contentsOf: url) == original else {
                try? FileManager.default.removeItem(at: temp)
                continue
            }
            guard rename(temp.path, url.path) == 0 else {
                let error = errno
                try? FileManager.default.removeItem(at: temp)
                throw TerminalAccountError.renameFailed(error)
            }
            return
        }
        throw TerminalAccountError.concurrentModification
    }
}

public enum TerminalAccountImporter {
    /// Makes sure the terminal's current account is listed. Its credentials stay owned by Claude Code.
    @discardableResult
    public static func importIfNeeded(store: AccountStore, terminal: TerminalAccountFile, now: Date) throws -> Account? {
        guard let json = try terminal.readOAuthAccountJSON(),
              let identity = TerminalAccountFile.identity(fromOAuthAccountJSON: json),
              let o = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let organizationName = o["organizationName"] as? String
        var account = try store.account(id: identity.accountID) ?? Account(
            id: identity.accountID, accountUuid: identity.accountUuid, organizationUuid: identity.organizationUuid,
            email: identity.email, displayName: nil, organizationName: nil, organizationType: nil, rateLimitTier: nil,
            subscriptionType: nil,
            label: Account.defaultLabel(email: identity.email, organizationName: organizationName),
            colorIndex: try store.nextColorIndex(), addedAt: now, status: .ok, oauthAccountJSON: nil)
        account.email = identity.email
        account.displayName = o["displayName"] as? String ?? account.displayName
        account.organizationName = organizationName ?? account.organizationName
        account.organizationType = o["organizationType"] as? String ?? account.organizationType
        account.rateLimitTier = o["organizationRateLimitTier"] as? String ?? account.rateLimitTier
        account.oauthAccountJSON = json
        return try store.upsert(account)
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter "AccountsTests|TerminalAccountTests"`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): account store and lock-safe ~/.claude.json oauthAccount swap"
```

---

### Task 9: Token refresh and credential ownership

**Files:**
- Create: `Sources/UsageCore/TokenRefresher.swift`, `Sources/UsageCore/CredentialProvider.swift`
- Test: `Tests/UsageCoreTests/TokenRefresherTests.swift`, `Tests/UsageCoreTests/CredentialProviderTests.swift`

**Interfaces:**
- Consumes: `HTTPClient` (Task 3), `DateProvider` (Task 1), `OAuthCredentials`, `CredentialsJSON`, `ClaudeCodeKeychain`, `SecretStore` (Task 2), `Account`, `AccountStore` (Task 8); test helpers `FakeHTTPClient`, `OAuthCredentials.fake`, `Account.fake`.
- Produces:
  - `public enum OAuthEndpoint { static let token: URL; static let clientID: String }` (values from Global Constraints).
  - `public enum RefreshError: Error, Equatable { case invalidGrant, http(Int), network(String), decoding, missingCredentials, refreshDisabled }`.
  - `public struct TokenRefresher: Sendable { public init(http: any HTTPClient, now: any DateProvider); public func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials }` — POST JSON `{"grant_type":"refresh_token","refresh_token":…,"client_id":…}`.
  - `public enum TokenOwner: Sendable, Equatable { case claudeCode, app }`; `public enum RefreshPolicy { static let appLeadTime: TimeInterval = 600; static let claudeCodeGrace: TimeInterval = 300; static func shouldRefresh(_ c: OAuthCredentials, owner: TokenOwner, now: Date) -> Bool }`.
  - `public struct TerminalKeychainItem: Sendable, Equatable { public var service: String; public var account: String; public init(service: String, account: String); public static func live() -> TerminalKeychainItem }`.
  - `public protocol CredentialProviding: Sendable { func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String }`.
  - `public struct CredentialProvider: CredentialProviding` — `public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem, refresher: TokenRefresher, now: any DateProvider, allowRefresh: Bool = true)`.

- [ ] **Step 1: Write the failing tests**

`Tests/UsageCoreTests/TokenRefresherTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct TokenRefresherTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))

    @Test func postsRefreshGrantAndBuildsNewCredentials() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800,"scope":"user:inference user:profile"}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.accessToken == "at-new")
        #expect(fresh.refreshToken == "rt-new")
        #expect(fresh.expiresAt == (1_790_870_400 + 28_800) * 1_000)
        #expect(fresh.scopes == ["user:inference", "user:profile"])
        #expect(fresh.subscriptionType == "max")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["grant_type": "refresh_token", "refresh_token": "rt-old",
                         "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
    }

    @Test func keepsOldRefreshTokenAndScopesWhenAbsent() async throws {
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-new","expires_in":3600}"#)])
        let fresh = try await TokenRefresher(http: http, now: now).refresh(.fake("old"))
        #expect(fresh.refreshToken == "rt-old")
        #expect(fresh.scopes == OAuthCredentials.fake("old").scopes)
    }

    @Test func mapsErrors() async {
        func run(_ stub: FakeHTTPClient.Stub) async -> RefreshError? {
            do { _ = try await TokenRefresher(http: FakeHTTPClient([stub]), now: now).refresh(.fake("x")); return nil }
            catch { return error as? RefreshError }
        }
        #expect(await run(FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)) == .invalidGrant)
        #expect(await run(FakeHTTPClient.json(401, #"{"error":"invalid_grant","error_description":"revoked"}"#)) == .invalidGrant)
        #expect(await run(FakeHTTPClient.json(500, "{}")) == .http(500))
        #expect(await run(FakeHTTPClient.json(200, "not json")) == .decoding)
    }

    @Test(arguments: [
        (TokenOwner.app, 5 * 60.0, true), (TokenOwner.app, 30 * 60.0, false),
        (TokenOwner.claudeCode, -60.0, false), (TokenOwner.claudeCode, -6 * 60.0, true),
        (TokenOwner.claudeCode, 60.0, false),
    ])
    func refreshPolicy(owner: TokenOwner, secondsUntilExpiry: Double, expected: Bool) {
        let expires = Int64((now.now().timeIntervalSince1970 + secondsUntilExpiry) * 1_000)
        #expect(RefreshPolicy.shouldRefresh(.fake("x", expiresAt: expires), owner: owner, now: now.now()) == expected)
    }
}
```

`Tests/UsageCoreTests/CredentialProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct CredentialProviderTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
    var future: Int64 { Int64((now.now().timeIntervalSince1970 + 3_600) * 1_000) }
    var longExpired: Int64 { Int64((now.now().timeIntervalSince1970 - 600) * 1_000) }
    var nearlyExpired: Int64 { Int64((now.now().timeIntervalSince1970 + 120) * 1_000) }

    func terminalBlob(_ creds: OAuthCredentials) throws -> Data {
        try CredentialsJSON.merging(creds, into: Data(#"{"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8))
    }

    func provider(http: FakeHTTPClient, secrets: InMemorySecretStore, store: AccountStore,
                  allowRefresh: Bool = true) -> CredentialProvider {
        CredentialProvider(store: store, secrets: secrets, terminalItem: item,
                           refresher: TokenRefresher(http: http, now: now), now: now, allowRefresh: allowRefresh)
    }

    @Test func terminalFreshTokenIsReadNotRefreshed() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: future)))
        let http = FakeHTTPClient([])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T")
        #expect(http.requests.isEmpty)
    }

    @Test func terminalExpiredRefreshesAndKeepsMcpOAuth() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-T2","refresh_token":"rt-T2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-T2")
        let raw = try #require(try secrets.read(service: item.service, account: item.account))
        #expect(try CredentialsJSON.claudeAiOauth(from: raw)?.refreshToken == "rt-T2")
        let o = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(((o["mcpOAuth"] as? [String: Any])?["linear"] as? [String: Any])?["accessToken"] as? String == "m1")
    }

    @Test func terminalInvalidGrantUsesTokenClaudeCodeJustRefreshed() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let http = FakeHTTPClient([FakeHTTPClient.json(400, #"{"error":"invalid_grant"}"#)])
        let replacement = try terminalBlob(.fake("byClaudeCode", expiresAt: future))
        let service = item.service, account = item.account
        http.onSend = { _ in try? secrets.write(service: service, account: account, data: replacement) }
        let p = provider(http: http, secrets: secrets, store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        #expect(try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false) == "at-byClaudeCode")
    }

    @Test func terminalExpiredInReadOnlyModeThrows() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try secrets.write(service: item.service, account: item.account, data: terminalBlob(.fake("T", expiresAt: longExpired)))
        let p = provider(http: FakeHTTPClient([]), secrets: secrets,
                         store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets), allowRefresh: false)
        await #expect(throws: RefreshError.refreshDisabled) {
            _ = try await p.accessToken(for: .fake("T"), isTerminal: true, forceRefresh: false)
        }
    }

    @Test func appOwnedNearExpiryRefreshesAndSaves() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: nearlyExpired), for: Account.fake("B").id)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-B2","refresh_token":"rt-B2","expires_in":28800}"#)])
        let p = provider(http: http, secrets: secrets, store: store)
        #expect(try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false) == "at-B2")
        #expect(try store.credentials(for: Account.fake("B").id)?.refreshToken == "rt-B2")
    }

    @Test func appOwnedForceRefreshEvenWhenFresh() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let store = AccountStore(fileURL: dir.file("a.json"), secrets: secrets)
        try store.setCredentials(.fake("B", expiresAt: future), for: Account.fake("B").id)
        let http = FakeHTTPClient([FakeHTTPClient.json(200, #"{"access_token":"at-B3","expires_in":28800}"#)])
        #expect(try await provider(http: http, secrets: secrets, store: store)
            .accessToken(for: .fake("B"), isTerminal: false, forceRefresh: true) == "at-B3")
    }

    @Test func missingAppCredentials() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let p = provider(http: FakeHTTPClient([]), secrets: secrets,
                         store: AccountStore(fileURL: dir.file("a.json"), secrets: secrets))
        await #expect(throws: RefreshError.missingCredentials) {
            _ = try await p.accessToken(for: .fake("B"), isTerminal: false, forceRefresh: false)
        }
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter "TokenRefresherTests|CredentialProviderTests"`
Expected: build errors — `cannot find 'TokenRefresher' in scope`.

- [ ] **Step 3: Implement**

`Sources/UsageCore/TokenRefresher.swift`:

```swift
import Foundation

public enum OAuthEndpoint {
    public static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}

public enum RefreshError: Error, Equatable {
    case invalidGrant
    case http(Int)
    case network(String)
    case decoding
    case missingCredentials
    case refreshDisabled
}

public enum TokenOwner: Sendable, Equatable {
    case claudeCode, app
}

public enum RefreshPolicy {
    /// App-owned tokens are refreshed ahead of expiry.
    public static let appLeadTime: TimeInterval = 10 * 60
    /// Claude Code refreshes its own token while in use; only step in when it is clearly idle.
    public static let claudeCodeGrace: TimeInterval = 5 * 60

    public static func shouldRefresh(_ creds: OAuthCredentials, owner: TokenOwner, now: Date) -> Bool {
        switch owner {
        case .app: return creds.expiresAtDate.timeIntervalSince(now) < appLeadTime
        case .claudeCode: return now.timeIntervalSince(creds.expiresAtDate) > claudeCodeGrace
        }
    }
}

public struct TokenRefresher: Sendable {
    let http: any HTTPClient
    let now: any DateProvider

    public init(http: any HTTPClient, now: any DateProvider) {
        self.http = http
        self.now = now
    }

    private struct Response: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: String?
    }

    public func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials {
        var request = URLRequest(url: OAuthEndpoint.token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": OAuthEndpoint.clientID,
        ])
        request.timeoutInterval = 20

        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await http.send(request) }
        catch let error as URLError { throw RefreshError.network(String(error.code.rawValue)) }

        guard (200..<300).contains(response.statusCode) else {
            if (400...401).contains(response.statusCode), String(decoding: data, as: UTF8.self).contains("invalid_grant") {
                throw RefreshError.invalidGrant
            }
            throw RefreshError.http(response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data) else { throw RefreshError.decoding }

        var fresh = creds
        fresh.accessToken = body.access_token
        fresh.refreshToken = body.refresh_token ?? creds.refreshToken
        fresh.expiresAt = Int64(((now.now().timeIntervalSince1970 + body.expires_in) * 1_000).rounded())
        if let scope = body.scope { fresh.scopes = scope.split(separator: " ").map(String.init) }
        return fresh
    }
}
```

`Sources/UsageCore/CredentialProvider.swift`:

```swift
import Foundation

public struct TerminalKeychainItem: Sendable, Equatable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static func live() -> TerminalKeychainItem {
        TerminalKeychainItem(service: ClaudeCodeKeychain.baseService, account: NSUserName())
    }
}

public protocol CredentialProviding: Sendable {
    func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String
}

/// Hands out access tokens while respecting who owns each refresh token (spec §6).
public struct CredentialProvider: CredentialProviding {
    let store: AccountStore
    let secrets: any SecretStore
    let terminalItem: TerminalKeychainItem
    let refresher: TokenRefresher
    let now: any DateProvider
    let allowRefresh: Bool

    public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem,
                refresher: TokenRefresher, now: any DateProvider, allowRefresh: Bool = true) {
        self.store = store
        self.secrets = secrets
        self.terminalItem = terminalItem
        self.refresher = refresher
        self.now = now
        self.allowRefresh = allowRefresh
    }

    public func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String {
        isTerminal ? try await terminalToken(forceRefresh: forceRefresh)
                   : try await appToken(for: account, forceRefresh: forceRefresh)
    }

    private func readTerminal() throws -> OAuthCredentials? {
        guard let raw = try secrets.read(service: terminalItem.service, account: terminalItem.account) else { return nil }
        return try CredentialsJSON.claudeAiOauth(from: raw)
    }

    private func terminalToken(forceRefresh: Bool) async throws -> String {
        guard let creds = try readTerminal() else { throw RefreshError.missingCredentials }
        let current = now.now()
        let expired = creds.expiresAtDate <= current
        guard RefreshPolicy.shouldRefresh(creds, owner: .claudeCode, now: current) || (forceRefresh && expired) else {
            return creds.accessToken
        }
        guard allowRefresh else { throw RefreshError.refreshDisabled }
        do {
            let fresh = try await refresher.refresh(creds)
            // Re-read right before writing so anything Claude Code stored meanwhile (mcpOAuth…) survives.
            let latest = try secrets.read(service: terminalItem.service, account: terminalItem.account)
            try secrets.write(service: terminalItem.service, account: terminalItem.account,
                              data: CredentialsJSON.merging(fresh, into: latest))
            return fresh.accessToken
        } catch RefreshError.invalidGrant {
            // Claude Code may have rotated the token while we were refreshing.
            if let again = try readTerminal(), again.refreshToken != creds.refreshToken, again.expiresAtDate > now.now() {
                return again.accessToken
            }
            throw RefreshError.invalidGrant
        }
    }

    private func appToken(for account: Account, forceRefresh: Bool) async throws -> String {
        guard let creds = try store.credentials(for: account.id) else { throw RefreshError.missingCredentials }
        guard forceRefresh || RefreshPolicy.shouldRefresh(creds, owner: .app, now: now.now()) else {
            return creds.accessToken
        }
        guard allowRefresh else {
            if creds.expiresAtDate > now.now() { return creds.accessToken }
            throw RefreshError.refreshDisabled
        }
        let fresh = try await refresher.refresh(creds)
        try store.setCredentials(fresh, for: account.id)
        return fresh.accessToken
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "TokenRefresherTests|CredentialProviderTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): token refresh with single-owner rule for terminal and app accounts"
```

---

### Task 10: Account switcher ("Use in terminal")

**Files:**
- Create: `Sources/UsageCore/AccountSwitcher.swift`
- Test: `Tests/UsageCoreTests/AccountSwitcherTests.swift`

**Interfaces:**
- Consumes: `AccountStore`, `Account`, `TerminalAccountFile`, `TerminalAccountImporter` (Task 8); `SecretStore`, `CredentialsJSON` (Task 2); `TerminalKeychainItem` (Task 9); `DateProvider` (Task 1); test helpers `Account.fake`, `OAuthCredentials.fake`, `ClaudeJSONFixture`, `TempDir`.
- Produces:
  - `public enum SwitchError: Error, Equatable { case unknownAccount, missingCredentials, alreadyActive, needsSignIn }`.
  - `public struct SwitchResult: Sendable, Equatable { public var fromID: String?; public var toID: String }`.
  - `public struct AccountSwitcher: Sendable` — `public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem, terminalFile: TerminalAccountFile, now: any DateProvider)`; `public func switchTerminal(to targetID: String) throws -> SwitchResult`.

- [ ] **Step 1: Write the failing tests**

`Tests/UsageCoreTests/AccountSwitcherTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct AccountSwitcherTests {
    let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    static let mcp = Data(#"{"mcpOAuth":{"linear":{"accessToken":"m1"}}}"#.utf8)

    struct World {
        let dir: TempDir
        let secrets: InMemorySecretStore
        let store: AccountStore
        let file: TerminalAccountFile
        let switcher: AccountSwitcher
    }

    /// Terminal on account A (Claude Code has refreshed its token: "A-refreshed"); B is app-owned.
    func world(claudeJSON: String? = nil, listA: Bool = true) throws -> World {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        try Data((claudeJSON ?? ClaudeJSONFixture.file(tag: "A", email: "a@example.com")).utf8).write(to: dir.file(".claude.json"))
        try secrets.write(service: item.service, account: item.account,
                          data: CredentialsJSON.merging(.fake("A-refreshed"), into: Self.mcp))
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: secrets)
        if listA { try store.upsert(.fake("A")) }
        try store.upsert(.fake("B"))
        try store.setCredentials(.fake("B"), for: Account.fake("B").id)
        let file = TerminalAccountFile(url: dir.file(".claude.json"))
        return World(dir: dir, secrets: secrets, store: store, file: file,
                     switcher: AccountSwitcher(store: store, secrets: secrets, terminalItem: item, terminalFile: file, now: now))
    }

    func terminalCreds(_ w: World) throws -> OAuthCredentials? {
        try w.secrets.read(service: item.service, account: item.account).flatMap(CredentialsJSON.claudeAiOauth(from:))
    }

    @Test func switchesKeychainAndClaudeJSONAndSavesOutgoing() throws {
        let w = try world()
        let result = try w.switcher.switchTerminal(to: Account.fake("B").id)
        #expect(result == SwitchResult(fromID: "acc-A:org-A", toID: "acc-B:org-B"))
        #expect(try terminalCreds(w) == .fake("B"))
        let raw = try #require(try w.secrets.read(service: item.service, account: item.account))
        #expect(String(decoding: raw, as: UTF8.self).contains("\"m1\""))
        #expect(try w.file.currentIdentity()?.accountID == "acc-B:org-B")
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-refreshed"))
        let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: w.dir.file(".claude.json"))) as? [String: Any])
        #expect(o["numStartups"] as? Int == 7)
    }

    @Test func switchingBackRestoresTheOriginalAccount() throws {
        let w = try world()
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        try w.switcher.switchTerminal(to: Account.fake("A").id)
        #expect(try terminalCreds(w) == .fake("A-refreshed"))
        #expect(try w.file.currentIdentity()?.accountID == "acc-A:org-A")
        #expect(try w.store.credentials(for: "acc-B:org-B") == .fake("B"))
    }

    @Test func refusesActiveMissingOrSignedOutTargets() throws {
        let w = try world()
        #expect(throws: SwitchError.alreadyActive) { try w.switcher.switchTerminal(to: "acc-A:org-A") }
        #expect(throws: SwitchError.unknownAccount) { try w.switcher.switchTerminal(to: "nope") }
        try w.store.upsert(.fake("C"))
        #expect(throws: SwitchError.missingCredentials) { try w.switcher.switchTerminal(to: "acc-C:org-C") }
        try w.store.update(id: "acc-B:org-B") { $0.status = .needsSignIn }
        #expect(throws: SwitchError.needsSignIn) { try w.switcher.switchTerminal(to: "acc-B:org-B") }
        #expect(try terminalCreds(w) == .fake("A-refreshed"))
    }

    @Test func rollsBackKeychainWhenClaudeJSONCannotBeWritten() throws {
        let w = try world(claudeJSON: "[]")
        let before = try w.secrets.read(service: item.service, account: item.account)
        #expect(throws: TerminalAccountError.notAnObject) { try w.switcher.switchTerminal(to: Account.fake("B").id) }
        #expect(try w.secrets.read(service: item.service, account: item.account) == before)
    }

    @Test func unlistedTerminalAccountIsImportedBeforeSwitching() throws {
        let w = try world(listA: false)
        try w.switcher.switchTerminal(to: Account.fake("B").id)
        #expect(try w.store.account(id: "acc-A:org-A") != nil)
        #expect(try w.store.credentials(for: "acc-A:org-A") == .fake("A-refreshed"))
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter AccountSwitcherTests`
Expected: build errors — `cannot find 'AccountSwitcher' in scope`.

- [ ] **Step 3: Implement**

`Sources/UsageCore/AccountSwitcher.swift`:

```swift
import Foundation

public enum SwitchError: Error, Equatable {
    case unknownAccount, missingCredentials, alreadyActive, needsSignIn
}

public struct SwitchResult: Sendable, Equatable {
    public var fromID: String?
    public var toID: String
}

/// "Use in terminal" (spec §6): points Claude Code's default Keychain item and ~/.claude.json at another account.
public struct AccountSwitcher: Sendable {
    let store: AccountStore
    let secrets: any SecretStore
    let terminalItem: TerminalKeychainItem
    let terminalFile: TerminalAccountFile
    let now: any DateProvider

    public init(store: AccountStore, secrets: any SecretStore, terminalItem: TerminalKeychainItem,
                terminalFile: TerminalAccountFile, now: any DateProvider) {
        self.store = store
        self.secrets = secrets
        self.terminalItem = terminalItem
        self.terminalFile = terminalFile
        self.now = now
    }

    @discardableResult
    public func switchTerminal(to targetID: String) throws -> SwitchResult {
        guard let target = try store.account(id: targetID) else { throw SwitchError.unknownAccount }
        let identity = try terminalFile.currentIdentity()
        if identity?.accountID == targetID { throw SwitchError.alreadyActive }
        guard target.status != .needsSignIn else { throw SwitchError.needsSignIn }
        guard let targetCreds = try store.credentials(for: targetID) else { throw SwitchError.missingCredentials }

        let originalItem = try secrets.read(service: terminalItem.service, account: terminalItem.account)

        // 1. Keep the outgoing account: list it and keep its (possibly just refreshed) token as app-owned.
        if let identity {
            try TerminalAccountImporter.importIfNeeded(store: store, terminal: terminalFile, now: now.now())
            if let originalItem, let outgoing = try CredentialsJSON.claudeAiOauth(from: originalItem) {
                try store.setCredentials(outgoing, for: identity.accountID)
            }
        }

        // 2. Hand Claude Code the target's token, keeping mcpOAuth and every other key.
        try secrets.write(service: terminalItem.service, account: terminalItem.account,
                          data: CredentialsJSON.merging(targetCreds, into: originalItem))

        // 3. Point ~/.claude.json at the target; undo step 2 if that fails.
        do {
            try terminalFile.replaceOAuthAccount(with: target.oauthAccountPayload())
        } catch {
            if let originalItem {
                try? secrets.write(service: terminalItem.service, account: terminalItem.account, data: originalItem)
            } else {
                try? secrets.delete(service: terminalItem.service, account: terminalItem.account)
            }
            throw error
        }
        return SwitchResult(fromID: identity?.accountID, toID: targetID)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter AccountSwitcherTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): switch the terminal's Claude account without touching MCP logins"
```

---

### Task 11: Add-account login flow

**Files:**
- Create: `Sources/UsageCore/ProcessRunner.swift`, `Sources/UsageCore/ClaudeBinaryLocator.swift`, `Sources/UsageCore/LoginFlow.swift`
- Create: `Tests/UsageCoreTests/Support/FakeProcessRunner.swift`
- Test: `Tests/UsageCoreTests/LoginFlowTests.swift`, `Tests/UsageCoreTests/ProcessRunnerTests.swift`

**Interfaces:**
- Consumes: `SecretStore`, `CredentialsJSON`, `ClaudeCodeKeychain`, `OAuthCredentials` (Task 2); `UsageAPI`, `Profile` (Task 3); `Account`, `AccountStore`, `TerminalAccountFile` (Task 8); `DateProvider` (Task 1); test helpers `FakeHTTPClient`, `Fixtures.profileJSON`, `ClaudeJSONFixture`, `Account.fake`, `OAuthCredentials.fake`, `TempDir`.
- Produces:
  - `public protocol ProcessRunner: Sendable { func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Int32 }`; `public enum ProcessRunnerError: Error, Equatable { case timedOut }`; `public struct FoundationProcessRunner: ProcessRunner` (`public init()`; cancellation terminates the child and throws `CancellationError`).
  - `public enum ClaudeBinaryLocator { static func candidates(home: URL, pathEnv: String?) -> [URL]; static func locate(home: URL, pathEnv: String?, isExecutable: (String) -> Bool = …) -> URL? }`; `public enum ShellEnvironment { static func loginPATH() -> String? }`.
  - `public enum LoginMethod: Sendable, Equatable { case google, email(String) }`; `public enum LoginError: Error, Equatable { case failed(exitCode: Int32), timedOut, cancelled, noCredentials }`.
  - `public struct LoginFlow: Sendable` — `public init(claude: URL, runner: any ProcessRunner, secrets: any SecretStore, api: UsageAPI, store: AccountStore, workRoot: URL, keychainAccount: String, now: any DateProvider)`; `public static func arguments(for: LoginMethod) -> [String]`; `public func addAccount(method: LoginMethod, timeout: TimeInterval = 600) async throws -> Account`.
  - Test helper `final class FakeProcessRunner: ProcessRunner, @unchecked Sendable` with `enum Behavior { case signIn(OAuthCredentials, oauthAccount: String), exit(Int32), fail(any Error) }`, `init(_ behavior: Behavior, secrets: InMemorySecretStore, keychainAccount: String = "tester")`, `var recorded: [(arguments: [String], environment: [String: String])]`.

- [ ] **Step 1: Add the fake runner**

`Tests/UsageCoreTests/Support/FakeProcessRunner.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/LoginFlowTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct LoginFlowTests {
    let now = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    static let studioProfile = Fixtures.profileJSON(accountUuid: "acc-N", email: "studio@example.com",
                                                    orgUuid: "org-N", orgName: "Studio")

    func make(_ runner: FakeProcessRunner, secrets: InMemorySecretStore, dir: TempDir,
              profile: String = LoginFlowTests.studioProfile) -> (LoginFlow, AccountStore, URL) {
        let store = AccountStore(fileURL: dir.file("accounts.json"), secrets: secrets)
        let api = UsageAPI(http: FakeHTTPClient([FakeHTTPClient.json(200, profile)]), now: now)
        let workRoot = dir.url.appendingPathComponent("login", isDirectory: true)
        let flow = LoginFlow(claude: URL(fileURLWithPath: "/usr/local/bin/claude"), runner: runner, secrets: secrets,
                             api: api, store: store, workRoot: workRoot, keychainAccount: "tester", now: now)
        return (flow, store, workRoot)
    }

    func leftovers(_ workRoot: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: workRoot.path)) ?? []
    }

    @Test func arguments() {
        #expect(LoginFlow.arguments(for: .google) == ["auth", "login"])
        #expect(LoginFlow.arguments(for: .email("a@b.co")) == ["auth", "login", "--email", "a@b.co"])
    }

    @Test func signInStoresAccountAndCleansUp() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("N"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "N", email: "studio@example.com")),
                                       secrets: secrets)
        let (flow, store, workRoot) = make(runner, secrets: secrets, dir: dir)
        let account = try await flow.addAccount(method: .email("studio@example.com"))

        #expect(account.id == "acc-N:org-N")
        #expect(account.email == "studio@example.com")
        #expect(account.label == "Studio")
        #expect(account.status == .ok)
        #expect(account.oauthAccountJSON != nil)
        #expect(try store.credentials(for: account.id) == .fake("N"))
        #expect(secrets.allKeys == ["Claude Usage|acc-N:org-N"])
        #expect(leftovers(workRoot).isEmpty)
        let call = try #require(runner.recorded.first)
        #expect(call.arguments == ["auth", "login", "--email", "studio@example.com"])
        #expect(call.environment["CLAUDE_CONFIG_DIR"]?.hasPrefix(workRoot.path) == true)
    }

    @Test func reLoginKeepsLabelAndClearsNeedsSignIn() async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let runner = FakeProcessRunner(.signIn(.fake("A2"), oauthAccount: ClaudeJSONFixture.oauthAccount(tag: "A", email: "a@example.com")),
                                       secrets: secrets)
        let (flow, store, _) = make(runner, secrets: secrets, dir: dir,
                                    profile: Fixtures.profileJSON(accountUuid: "acc-A", email: "a@example.com", orgUuid: "org-A"))
        try store.upsert(.fake("A", label: "Work", status: .needsSignIn))
        let account = try await flow.addAccount(method: .google)
        #expect(account.label == "Work")
        #expect(account.status == .ok)
        #expect(try store.load().count == 1)
        #expect(try store.credentials(for: "acc-A:org-A") == .fake("A2"))
    }

    @Test(arguments: [
        (FakeProcessRunner.Behavior.exit(1), LoginError.failed(exitCode: 1)),
        (FakeProcessRunner.Behavior.exit(0), LoginError.noCredentials),
        (FakeProcessRunner.Behavior.fail(CancellationError()), LoginError.cancelled),
        (FakeProcessRunner.Behavior.fail(ProcessRunnerError.timedOut), LoginError.timedOut),
    ])
    func failuresCleanUp(behavior: FakeProcessRunner.Behavior, expected: LoginError) async throws {
        let dir = try TempDir()
        let secrets = InMemorySecretStore()
        let (flow, store, workRoot) = make(FakeProcessRunner(behavior, secrets: secrets), secrets: secrets, dir: dir)
        await #expect(throws: expected) { _ = try await flow.addAccount(method: .google) }
        #expect(leftovers(workRoot).isEmpty)
        #expect(secrets.allKeys.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test func locatorPrefersPathThenKnownLocations() {
        let home = URL(fileURLWithPath: "/Users/x")
        let candidates = ClaudeBinaryLocator.candidates(home: home, pathEnv: "/opt/homebrew/bin:/usr/bin")
        #expect(candidates.map(\.path) == ["/opt/homebrew/bin/claude", "/usr/bin/claude", "/Users/x/.local/bin/claude",
                                           "/Users/x/.claude/local/claude", "/usr/local/bin/claude"])
        let found = ClaudeBinaryLocator.locate(home: home, pathEnv: "/usr/bin") { $0 == "/Users/x/.local/bin/claude" }
        #expect(found?.path == "/Users/x/.local/bin/claude")
        #expect(ClaudeBinaryLocator.locate(home: home, pathEnv: nil) { _ in false } == nil)
    }
}
```

`Tests/UsageCoreTests/ProcessRunnerTests.swift` (real, harmless processes):

```swift
import Foundation
import Testing
@testable import UsageCore

struct ProcessRunnerTests {
    let runner = FoundationProcessRunner()

    @Test func returnsExitStatus() async throws {
        let status = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"],
                                          environment: [:], timeout: 5)
        #expect(status == 3)
    }

    @Test func passesEnvironment() async throws {
        let status = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", "test \"$CLAUDE_CONFIG_DIR\" = /tmp/x"],
                                          environment: ["CLAUDE_CONFIG_DIR": "/tmp/x"], timeout: 5)
        #expect(status == 0)
    }

    @Test func timesOut() async {
        let started = Date()
        await #expect(throws: ProcessRunnerError.timedOut) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                     environment: [:], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancellationTerminatesTheProcess() async {
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"],
                                 environment: [:], timeout: 10)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter "LoginFlowTests|ProcessRunnerTests"`
Expected: build errors — `cannot find 'LoginFlow' in scope`.

- [ ] **Step 4: Implement**

`Sources/UsageCore/ProcessRunner.swift`:

```swift
import Foundation

public protocol ProcessRunner: Sendable {
    /// Runs to completion and returns the exit status. Cancelling the calling task terminates the process
    /// and throws CancellationError.
    func run(executable: URL, arguments: [String], environment: [String: String],
             timeout: TimeInterval) async throws -> Int32
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
        func terminate() { if process.isRunning { process.terminate() } }
    }

    public func run(executable: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval) async throws -> Int32 {
        let box = Box()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.environment = environment
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        do { try box.process.run() } catch { continuation.resume(throwing: error) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw ProcessRunnerError.timedOut
                }
                defer {
                    group.cancelAll()
                    box.terminate()
                }
                guard let status = try await group.next() else { throw ProcessRunnerError.timedOut }
                try Task.checkCancellation()
                return status
            }
        } onCancel: {
            box.terminate()
        }
    }
}
```

`Sources/UsageCore/ClaudeBinaryLocator.swift`:

```swift
import Foundation

public enum ClaudeBinaryLocator {
    public static func candidates(home: URL, pathEnv: String?) -> [URL] {
        let fromPath = (pathEnv ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        let known = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        var seen = Set<String>()
        return (fromPath + known).filter { seen.insert($0.path).inserted }
    }

    public static func locate(home: URL, pathEnv: String?,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates(home: home, pathEnv: pathEnv).first { isExecutable($0.path) }
    }
}

public enum ShellEnvironment {
    /// PATH as the user's login shell sets it — apps opened from Finder start with a minimal PATH.
    public static func loginPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", "printf '%s' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // Login scripts may print banners; PATH is the last line.
        return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
    }
}
```

`Sources/UsageCore/LoginFlow.swift`:

```swift
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
    let now: any DateProvider

    public init(claude: URL, runner: any ProcessRunner, secrets: any SecretStore, api: UsageAPI, store: AccountStore,
                workRoot: URL, keychainAccount: String, now: any DateProvider) {
        self.claude = claude
        self.runner = runner
        self.secrets = secrets
        self.api = api
        self.store = store
        self.workRoot = workRoot
        self.keychainAccount = keychainAccount
        self.now = now
    }

    public static func arguments(for method: LoginMethod) -> [String] {
        switch method {
        case .google: return ["auth", "login"]
        case .email(let email): return ["auth", "login", "--email", email]
        }
    }

    public func addAccount(method: LoginMethod, timeout: TimeInterval = 600) async throws -> Account {
        let dir = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = ClaudeCodeKeychain.serviceName(configDir: dir.path)
        defer {
            try? secrets.delete(service: service, account: keychainAccount)
            try? FileManager.default.removeItem(at: dir)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = dir.path
        let status: Int32
        do {
            status = try await runner.run(executable: claude, arguments: Self.arguments(for: method),
                                          environment: environment, timeout: timeout)
        } catch ProcessRunnerError.timedOut {
            throw LoginError.timedOut
        } catch is CancellationError {
            throw LoginError.cancelled
        }
        guard status == 0 else { throw LoginError.failed(exitCode: status) }

        guard let creds = try readCredentials(service: service, dir: dir) else { throw LoginError.noCredentials }
        let profile = try await api.profile(accessToken: creds.accessToken)
        let oauthJSON = try TerminalAccountFile(url: dir.appendingPathComponent(".claude.json")).readOAuthAccountJSON()
        return try register(profile: profile, creds: creds, oauthAccountJSON: oauthJSON)
    }

    private func readCredentials(service: String, dir: URL) throws -> OAuthCredentials? {
        if let raw = try secrets.read(service: service, account: keychainAccount),
           let creds = try CredentialsJSON.claudeAiOauth(from: raw) {
            return creds
        }
        // Some setups store a credentials file inside the config dir instead of the Keychain.
        guard let raw = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")) else { return nil }
        return try CredentialsJSON.claudeAiOauth(from: raw)
    }

    private func register(profile: Profile, creds: OAuthCredentials, oauthAccountJSON: Data?) throws -> Account {
        let id = profile.accountID
        var account = try store.account(id: id) ?? Account(
            id: id, accountUuid: profile.accountUuid, organizationUuid: profile.organizationUuid, email: profile.email,
            displayName: nil, organizationName: nil, organizationType: nil, rateLimitTier: nil, subscriptionType: nil,
            label: Account.defaultLabel(email: profile.email, organizationName: profile.organizationName),
            colorIndex: try store.nextColorIndex(), addedAt: now.now(), status: .ok, oauthAccountJSON: nil)
        account.email = profile.email
        account.displayName = profile.displayName
        account.organizationName = profile.organizationName
        account.organizationType = profile.organizationType
        account.rateLimitTier = creds.rateLimitTier ?? profile.rateLimitTier
        account.subscriptionType = creds.subscriptionType
        account.status = .ok
        if let oauthAccountJSON { account.oauthAccountJSON = oauthAccountJSON }
        account.oauthAccountJSON = try account.oauthAccountPayload()
        try store.upsert(account)
        try store.setCredentials(creds, for: id)
        return account
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "LoginFlowTests|ProcessRunnerTests"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): add accounts through Claude Code's own login in a temp config dir"
```

---

### Task 12: Poller, notifier and state cache

**Files:**
- Create: `Sources/UsageCore/Poller.swift`, `Sources/UsageCore/Notifier.swift`, `Sources/UsageCore/StateCache.swift`
- Create: `Tests/UsageCoreTests/Support/FakeCredentials.swift`
- Test: `Tests/UsageCoreTests/PollerTests.swift`, `Tests/UsageCoreTests/NotifierTests.swift`

**Interfaces:**
- Consumes: `UsageAPI`, `UsageAPIError`, `UsageSnapshot` (Task 3); `CredentialProviding`, `RefreshError` (Task 9); `Account`, `AccountStatus` (Task 8); `Format.percent` (Task 4); test helpers `FakeHTTPClient`, `Fixtures`, `UsageSnapshot.fake`, `Account.fake`, `TempDir`.
- Produces:
  - `public struct AccountRefreshState: Codable, Sendable, Equatable` — `snapshot: UsageSnapshot?`, `lastSuccess: Date?`, `status: AccountStatus`, `consecutiveRateLimits: Int`, `backoffUntil: Date?`, `isStale: Bool`; `static let initial`.
  - `public enum Backoff { static func delay(afterConsecutiveRateLimits n: Int) -> TimeInterval }` (60, 120, 240, 480, then 900 cap).
  - `public actor Poller` — `public init(api: UsageAPI, credentials: any CredentialProviding, now: any DateProvider, initial: [String: AccountRefreshState] = [:])`; `public func refresh(accounts: [Account], terminalID: String?, force: Bool = false) async -> [String: AccountRefreshState]` (returns states for the given accounts only); `public func currentStates() -> [String: AccountRefreshState]`; `public static func shouldRefreshOnOpen(lastSuccess: Date?, now: Date) -> Bool` (> 60 s or never).
  - `public struct NotificationEvent: Sendable, Equatable { enum Kind { case threshold(Int), reset }; id, accountID, limitID: String; kind; title, body: String }`.
  - `public struct NotifierState: Codable, Sendable, Equatable` — `fired: [String: [Int]]`, `highWindows: [String: Int64]`; `public init()`; `static func load(from: URL) -> NotifierState`; `func save(to: URL) throws`.
  - `public struct Notifier: Sendable` — `public init(thresholds: [Int], notifyOnReset: Bool)`; `public func evaluate(accountID: String, label: String, snapshot: UsageSnapshot, state: inout NotifierState, now: Date) -> [NotificationEvent]`. Windows are keyed by the reset time rounded to the minute.
  - `public enum StateCache { static func load(from: URL) -> [String: AccountRefreshState]; static func save(_: [String: AccountRefreshState], to: URL) throws }`.

- [ ] **Step 1: Add the fake credential provider**

`Tests/UsageCoreTests/Support/FakeCredentials.swift`:

```swift
import Foundation
@testable import UsageCore

final class FakeCredentials: CredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(id: String, isTerminal: Bool, force: Bool)] = []
    var errors: [String: any Error] = [:]

    var calls: [(id: String, isTerminal: Bool, force: Bool)] { lock.locked { log } }

    func accessToken(for account: Account, isTerminal: Bool, forceRefresh: Bool) async throws -> String {
        try lock.locked {
            log.append((account.id, isTerminal, forceRefresh))
            if let error = errors[account.id] { throw error }
            return "tok-\(account.id)"
        }
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/UsageCoreTests/PollerTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct PollerTests {
    let clock = FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400))
    let b = Account.fake("B")
    var ok: FakeHTTPClient.Stub { FakeHTTPClient.json(200, Fixtures.usageJSON) }

    func poller(_ http: FakeHTTPClient, _ creds: FakeCredentials, initial: [String: AccountRefreshState] = [:]) -> Poller {
        Poller(api: UsageAPI(http: http, now: clock), credentials: creds, now: clock, initial: initial)
    }

    var cached: [String: AccountRefreshState] {
        [b.id: AccountRefreshState(snapshot: .fake(), lastSuccess: clock.now().addingTimeInterval(-600), status: .ok,
                                   consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)]
    }

    @Test func successStoresSnapshot() async {
        let states = await poller(FakeHTTPClient([ok]), FakeCredentials()).refresh(accounts: [b], terminalID: b.id)
        let s = states[b.id]
        #expect(s?.status == .ok)
        #expect(s?.snapshot?.limits.count == 3)
        #expect(s?.lastSuccess == clock.now())
        #expect(s?.isStale == false)
    }

    @Test func passesTerminalFlagToCredentials() async {
        let creds = FakeCredentials()
        _ = await poller(FakeHTTPClient([ok, ok]), creds).refresh(accounts: [.fake("A"), b], terminalID: b.id)
        #expect(creds.calls.map(\.isTerminal) == [false, true])
    }

    @Test func unauthorizedRetriesOnceWithForcedRefresh() async {
        let creds = FakeCredentials()
        let states = await poller(FakeHTTPClient([FakeHTTPClient.json(401, "{}"), ok]), creds)
            .refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .ok)
        #expect(creds.calls.map(\.force) == [false, true])
    }

    @Test func unauthorizedTwiceMarksNeedsSignInAndKeepsSnapshot() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(401, "{}"), FakeHTTPClient.json(401, "{}")])
        let states = await poller(http, FakeCredentials(), initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .needsSignIn)
        #expect(states[b.id]?.snapshot == .fake())
        #expect(states[b.id]?.isStale == true)
    }

    @Test func invalidGrantMarksNeedsSignIn() async {
        let creds = FakeCredentials()
        creds.errors[b.id] = RefreshError.invalidGrant
        let http = FakeHTTPClient([])
        let states = await poller(http, creds).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .needsSignIn)
        #expect(http.requests.isEmpty)
    }

    @Test func rateLimitBacksOffUntilForced() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}"), ok])
        let p = poller(http, FakeCredentials(), initial: cached)
        let first = await p.refresh(accounts: [b], terminalID: nil)
        #expect(first[b.id]?.status == .rateLimited)
        #expect(first[b.id]?.backoffUntil == clock.now().addingTimeInterval(60))
        #expect(first[b.id]?.snapshot == .fake())
        _ = await p.refresh(accounts: [b], terminalID: nil)
        #expect(http.requests.count == 1)
        let forced = await p.refresh(accounts: [b], terminalID: nil, force: true)
        #expect(forced[b.id]?.status == .ok)
        #expect(forced[b.id]?.consecutiveRateLimits == 0)
    }

    @Test func retryAfterHeaderExtendsBackoff() async {
        let http = FakeHTTPClient([FakeHTTPClient.json(429, "{}", headers: ["Retry-After": "300"])])
        let states = await poller(http, FakeCredentials()).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.backoffUntil == clock.now().addingTimeInterval(300))
    }

    @Test func networkErrorMarksOfflineAndStale() async {
        let http = FakeHTTPClient([])
        http.error = URLError(.notConnectedToInternet)
        let states = await poller(http, FakeCredentials(), initial: cached).refresh(accounts: [b], terminalID: nil)
        #expect(states[b.id]?.status == .offline)
        #expect(states[b.id]?.isStale == true)
        #expect(states[b.id]?.snapshot == .fake())
    }

    @Test func refreshOnOpenRule() {
        let now = clock.now()
        #expect(Poller.shouldRefreshOnOpen(lastSuccess: nil, now: now))
        #expect(!Poller.shouldRefreshOnOpen(lastSuccess: now.addingTimeInterval(-30), now: now))
        #expect(Poller.shouldRefreshOnOpen(lastSuccess: now.addingTimeInterval(-90), now: now))
    }

    @Test func backoffDelays() {
        #expect([1, 2, 3, 4, 5, 9].map { Backoff.delay(afterConsecutiveRateLimits: $0) } == [60, 120, 240, 480, 900, 900])
    }

    @Test func stateCacheRoundTrips() throws {
        let dir = try TempDir()
        try StateCache.save(cached, to: dir.file("snapshots.json"))
        #expect(StateCache.load(from: dir.file("snapshots.json")) == cached)
        #expect(StateCache.load(from: dir.file("missing.json")).isEmpty)
    }
}
```

`Tests/UsageCoreTests/NotifierTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct NotifierTests {
    let now = Date(timeIntervalSince1970: 1_790_870_400)
    let reset = Date(timeIntervalSince1970: 1_791_259_200)
    let notifier = Notifier(thresholds: [80, 95], notifyOnReset: true)

    func snapshot(_ weekly: Double, resets: Date? = nil) -> UsageSnapshot {
        .fake(session: 0, weekly: weekly, fable: nil, sessionResets: nil, weeklyResets: resets ?? reset)
    }

    @Test func crossing80FiresOncePerWindow() {
        var state = NotifierState()
        let first = notifier.evaluate(accountID: "A", label: "Work", snapshot: snapshot(81), state: &state, now: now)
        #expect(first.map(\.kind) == [.threshold(80)])
        #expect(first.first?.title == "Work · Week · all models at 81%")
        #expect(notifier.evaluate(accountID: "A", label: "Work", snapshot: snapshot(85), state: &state, now: now).isEmpty)
    }

    @Test func jumpFiresOnlyHighestThreshold() {
        var state = NotifierState()
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
            .map(\.kind) == [.threshold(95)])
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(97), state: &state, now: now).isEmpty)
    }

    @Test func jitteredResetDoesNotRefire() {
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(81), state: &state, now: now)
        let jittered = snapshot(82, resets: reset.addingTimeInterval(0.2))
        #expect(notifier.evaluate(accountID: "A", label: "U", snapshot: jittered, state: &state, now: now).isEmpty)
    }

    @Test func newWindowCanFireAgainAndResetIsAnnounced() {
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
        let nextWeek = reset.addingTimeInterval(UsageLimit.weekSeconds)
        let afterReset = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(3, resets: nextWeek),
                                           state: &state, now: reset.addingTimeInterval(60))
        #expect(afterReset.map(\.kind) == [.reset])
        #expect(afterReset.first?.title == "U · Week · all models reset")
        let again = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(81, resets: nextWeek),
                                      state: &state, now: reset.addingTimeInterval(3_600))
        #expect(again.map(\.kind) == [.threshold(80)])
    }

    @Test func disabledOptionsStayQuiet() {
        var state = NotifierState()
        let quiet = Notifier(thresholds: [], notifyOnReset: false)
        #expect(quiet.evaluate(accountID: "A", label: "U", snapshot: snapshot(99), state: &state, now: now).isEmpty)
        #expect(quiet.evaluate(accountID: "A", label: "U", snapshot: snapshot(1, resets: reset.addingTimeInterval(UsageLimit.weekSeconds)),
                               state: &state, now: reset.addingTimeInterval(60)).isEmpty)
    }

    @Test func stateRoundTrips() throws {
        let dir = try TempDir()
        var state = NotifierState()
        _ = notifier.evaluate(accountID: "A", label: "U", snapshot: snapshot(96), state: &state, now: now)
        try state.save(to: dir.file("notifier.json"))
        #expect(NotifierState.load(from: dir.file("notifier.json")) == state)
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --filter "PollerTests|NotifierTests"`
Expected: build errors — `cannot find 'Poller' in scope`.

- [ ] **Step 4: Implement**

`Sources/UsageCore/Poller.swift`:

```swift
import Foundation

public struct AccountRefreshState: Codable, Sendable, Equatable {
    public var snapshot: UsageSnapshot?
    public var lastSuccess: Date?
    public var status: AccountStatus
    public var consecutiveRateLimits: Int
    public var backoffUntil: Date?
    /// The snapshot is from an earlier refresh (the last one failed).
    public var isStale: Bool

    public static let initial = AccountRefreshState(snapshot: nil, lastSuccess: nil, status: .ok,
                                                    consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)
}

public enum Backoff {
    public static func delay(afterConsecutiveRateLimits n: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(n, 1) - 1)), 900)
    }
}

/// Fetches every account's usage independently; one failing account never blocks the others (spec §10).
public actor Poller {
    private let api: UsageAPI
    private let credentials: any CredentialProviding
    private let now: any DateProvider
    private var states: [String: AccountRefreshState]

    public init(api: UsageAPI, credentials: any CredentialProviding, now: any DateProvider,
                initial: [String: AccountRefreshState] = [:]) {
        self.api = api
        self.credentials = credentials
        self.now = now
        self.states = initial
    }

    public func currentStates() -> [String: AccountRefreshState] { states }

    public static func shouldRefreshOnOpen(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > 60
    }

    public func refresh(accounts: [Account], terminalID: String?, force: Bool = false) async -> [String: AccountRefreshState] {
        for account in accounts {
            let next = await refreshOne(account, isTerminal: account.id == terminalID, force: force)
            states[account.id] = next
        }
        let ids = Set(accounts.map(\.id))
        return states.filter { ids.contains($0.key) }
    }

    private func refreshOne(_ account: Account, isTerminal: Bool, force: Bool) async -> AccountRefreshState {
        var state = states[account.id] ?? .initial
        let current = now.now()
        if !force, let until = state.backoffUntil, until > current { return state }
        do {
            var token = try await credentials.accessToken(for: account, isTerminal: isTerminal, forceRefresh: false)
            let snapshot: UsageSnapshot
            do {
                snapshot = try await api.usage(accessToken: token)
            } catch UsageAPIError.unauthorized {
                token = try await credentials.accessToken(for: account, isTerminal: isTerminal, forceRefresh: true)
                snapshot = try await api.usage(accessToken: token)
            }
            return AccountRefreshState(snapshot: snapshot, lastSuccess: current, status: .ok,
                                       consecutiveRateLimits: 0, backoffUntil: nil, isStale: false)
        } catch UsageAPIError.unauthorized {
            state.status = .needsSignIn
        } catch RefreshError.invalidGrant {
            state.status = .needsSignIn
        } catch RefreshError.missingCredentials {
            state.status = .needsSignIn
        } catch UsageAPIError.rateLimited(let retryAfter) {
            state.consecutiveRateLimits += 1
            let wait = max(retryAfter ?? 0, Backoff.delay(afterConsecutiveRateLimits: state.consecutiveRateLimits))
            state.backoffUntil = current.addingTimeInterval(wait)
            state.status = .rateLimited
        } catch {
            state.status = .offline
        }
        state.isStale = state.snapshot != nil
        return state
    }
}
```

`Sources/UsageCore/Notifier.swift`:

```swift
import Foundation

public struct NotificationEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case threshold(Int)
        case reset
    }

    public var id: String
    public var accountID: String
    public var limitID: String
    public var kind: Kind
    public var title: String
    public var body: String
}

public struct NotifierState: Codable, Sendable, Equatable {
    /// "<account>|<limit>|<reset minute>" → thresholds already announced in that window.
    public var fired: [String: [Int]] = [:]
    /// "<account>|<limit>" → reset minute of a window that reached ≥ 95 %.
    public var highWindows: [String: Int64] = [:]

    public init() {}

    public static func load(from url: URL) -> NotifierState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NotifierState.self, from: data) else { return NotifierState() }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public struct Notifier: Sendable {
    public var thresholds: [Int]
    public var notifyOnReset: Bool

    public init(thresholds: [Int], notifyOnReset: Bool) {
        self.thresholds = thresholds
        self.notifyOnReset = notifyOnReset
    }

    /// The API recomputes `resets_at` on each call (microsecond jitter), so windows are keyed by the minute.
    static func minute(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 / 60).rounded()) }

    public func evaluate(accountID: String, label: String, snapshot: UsageSnapshot, state: inout NotifierState,
                         now: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        let nowMinute = Self.minute(now)
        for limit in snapshot.limits {
            let limitKey = "\(accountID)|\(limit.id)"
            let resetMinute = limit.resetsAt.map(Self.minute)

            if let highMinute = state.highWindows[limitKey], nowMinute >= highMinute, resetMinute != highMinute {
                state.highWindows[limitKey] = nil
                if notifyOnReset {
                    events.append(NotificationEvent(id: "\(limitKey)|reset|\(highMinute)", accountID: accountID,
                                                    limitID: limit.id, kind: .reset,
                                                    title: "\(label) · \(limit.title) reset",
                                                    body: "This limit is available again."))
                }
            }

            guard let resetMinute else { continue }
            let windowKey = "\(limitKey)|\(resetMinute)"
            var fired = Set(state.fired[windowKey] ?? [])
            let crossed = thresholds.sorted().filter { limit.percent >= Double($0) && !fired.contains($0) }
            if let top = crossed.last {
                events.append(NotificationEvent(id: "\(windowKey)|\(top)", accountID: accountID, limitID: limit.id,
                                                kind: .threshold(top),
                                                title: "\(label) · \(limit.title) at \(Format.percent(limit.percent))",
                                                body: "Crossed \(top)% of this limit."))
            }
            fired.formUnion(crossed)   // a jump 50 → 96 announces 95 only, and never 80 later in this window
            if !fired.isEmpty { state.fired[windowKey] = fired.sorted() }
            if limit.percent >= 95 { state.highWindows[limitKey] = resetMinute }
        }
        let weekAgo = nowMinute - 7 * 24 * 60
        state.fired = state.fired.filter { key, _ in (key.split(separator: "|").last.flatMap { Int64($0) } ?? nowMinute) > weekAgo }
        return events
    }
}
```

`Sources/UsageCore/StateCache.swift`:

```swift
import Foundation

/// Last known per-account state on disk, so the menu bar shows numbers instantly at launch.
public enum StateCache {
    public static func load(from url: URL) -> [String: AccountRefreshState] {
        guard let data = try? Data(contentsOf: url),
              let states = try? JSONDecoder().decode([String: AccountRefreshState].self, from: data) else { return [:] }
        return states
    }

    public static func save(_ states: [String: AccountRefreshState], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(states).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter "PollerTests|NotifierTests"`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/UsageCore Tests/UsageCoreTests
git commit -m "feat(core): per-account poller with backoff, threshold notifier and state cache"
```

---

### Task 13: Composition root, CLI and real-data verification

**Files:**
- Create: `Sources/UsageCore/CoreEnvironment.swift`
- Modify: `Sources/claude-usage-cli/CLI.swift` (replace the bootstrap)
- Create: `scripts/verify_spend.py`
- Test: `Tests/UsageCoreTests/CoreEnvironmentTests.swift`

**Interfaces:**
- Consumes: everything in `UsageCore` from Tasks 1–12.
- Produces:
  - `public struct CoreEnvironment: Sendable` — properties `paths: Paths`, `now: any DateProvider`, `secrets: any SecretStore`, `api: UsageAPI`, `store: AccountStore`, `terminalFile: TerminalAccountFile`, `terminalItem: TerminalKeychainItem`, `credentials: CredentialProvider`, `switcher: AccountSwitcher`, `pricing: PricingTable`; `public static func live(readOnly: Bool = false) throws -> CoreEnvironment`; `public static func make(paths: Paths, secrets: any SecretStore, http: any HTTPClient, now: any DateProvider, terminalItem: TerminalKeychainItem, readOnly: Bool) -> CoreEnvironment`; `public func makeIndex() throws -> TranscriptIndex`; `public func makeLoginFlow(claude: URL) -> LoginFlow`; `public func terminalAccountID() -> String?`; `public func locateClaude(customPath: String?) -> URL?`.
  - CLI `claude-usage-cli [--read-only] status | accounts | stats [--unknown-models] | reindex | switch <account-id> | login [--email <e>]`.

- [ ] **Step 1: Write the failing test**

`Tests/UsageCoreTests/CoreEnvironmentTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct CoreEnvironmentTests {
    @Test func wiresTheStatusFlowEndToEnd() async throws {
        let dir = try TempDir()
        let home = dir.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(ClaudeJSONFixture.file(tag: "A", email: "you@work.example").utf8).write(to: home.appendingPathComponent(".claude.json"))
        let secrets = InMemorySecretStore()
        let item = TerminalKeychainItem(service: "Claude Code-credentials", account: "tester")
        try secrets.write(service: item.service, account: item.account,
                          data: CredentialsJSON.merging(.fake("A", expiresAt: 4_102_444_800_000), into: nil))
        let http = FakeHTTPClient([FakeHTTPClient.json(200, Fixtures.usageJSON)])
        let env = CoreEnvironment.make(paths: Paths(home: home, appSupport: dir.url.appendingPathComponent("support")),
                                       secrets: secrets, http: http,
                                       now: FixedDateProvider(Date(timeIntervalSince1970: 1_790_870_400)),
                                       terminalItem: item, readOnly: true)

        try TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        #expect(env.terminalAccountID() == "acc-A:org-A")
        let states = await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .refresh(accounts: try env.store.load(), terminalID: env.terminalAccountID())
        #expect(states["acc-A:org-A"]?.snapshot?.limits.map(\.percent) == [25, 54, 64])
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer at-A")
        #expect(env.makeLoginFlow(claude: URL(fileURLWithPath: "/bin/true")).workRoot == env.paths.loginWorkRoot)
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test --filter CoreEnvironmentTests`
Expected: build error — `cannot find 'CoreEnvironment' in scope`.

- [ ] **Step 3: Implement the composition root**

`Sources/UsageCore/CoreEnvironment.swift`:

```swift
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

    public static func live(readOnly: Bool = false) throws -> CoreEnvironment {
        let paths = Paths.live()
        try paths.ensureAppSupport()
        return make(paths: paths, secrets: SecurityCLIStore(), http: URLSessionHTTPClient(),
                    now: SystemDateProvider(), terminalItem: .live(), readOnly: readOnly)
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

    public func makeLoginFlow(claude: URL) -> LoginFlow {
        LoginFlow(claude: claude, runner: FoundationProcessRunner(), secrets: secrets, api: api, store: store,
                  workRoot: paths.loginWorkRoot, keychainAccount: terminalItem.account, now: now)
    }

    public func terminalAccountID() -> String? {
        (try? terminalFile.currentIdentity())?.accountID
    }

    public func locateClaude(customPath: String?) -> URL? {
        if let customPath, FileManager.default.isExecutableFile(atPath: customPath) {
            return URL(fileURLWithPath: customPath)
        }
        return ClaudeBinaryLocator.locate(home: paths.home,
                                          pathEnv: ShellEnvironment.loginPATH() ?? ProcessInfo.processInfo.environment["PATH"])
    }
}
```

`LoginFlow.workRoot` is read by the test through `@testable import`; it stays internal.

- [ ] **Step 4: Run the test**

Run: `swift test --filter CoreEnvironmentTests`
Expected: PASS.

- [ ] **Step 5: Write the CLI**

Replace `Sources/claude-usage-cli/CLI.swift`:

```swift
import Foundation
import UsageCore

@main
enum CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let readOnly = args.contains("--read-only")
        args.removeAll { $0 == "--read-only" }
        do {
            let env = try CoreEnvironment.live(readOnly: readOnly)
            switch args.first ?? "status" {
            case "status": try await status(env)
            case "accounts": try accounts(env)
            case "stats": try await stats(env, showUnknown: args.contains("--unknown-models"))
            case "reindex": try await reindex(env)
            case "switch":
                guard args.count >= 2 else { return usage() }
                let result = try env.switcher.switchTerminal(to: args[1])
                print("Terminal switched to \(result.toID) — new `claude` sessions use it.")
            case "login":
                let email = args.firstIndex(of: "--email").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                try await login(env, email: email)
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func usage() {
        print("""
        usage: claude-usage-cli [--read-only] <command>
          status                  limits of every account (default)
          accounts                list accounts and their ids
          stats [--unknown-models]  API-equivalent spend on this Mac
          reindex                 rebuild the transcript index (after editing pricing.json)
          switch <account-id>     point the terminal at another account
          login [--email <e>]     add an account through `claude auth login`
        """)
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    static func status(_ env: CoreEnvironment) async throws {
        try TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        let accounts = try env.store.load()
        let terminalID = env.terminalAccountID()
        let states = await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .refresh(accounts: accounts, terminalID: terminalID, force: true)
        let now = env.now.now()
        for account in accounts {
            let state = states[account.id]
            let tag = account.id == terminalID ? "  ● terminal" : ""
            print("✻ \(account.label)  \(account.email)  \(account.plan)\(tag)  [\(state?.status.rawValue ?? "?")]")
            for limit in state?.snapshot?.limits ?? [] {
                let pace = PaceCalculator.pace(for: limit, now: now)
                print("  " + pad(limit.title, 20) + pad(Format.percent(limit.percent), 6)
                      + pad(Format.resetText(for: limit, now: now, calendar: .current), 28)
                      + "⎿ " + Format.paceLine(pace, percent: limit.percent, calendar: .current))
            }
        }
    }

    static func accounts(_ env: CoreEnvironment) throws {
        try TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        let terminalID = env.terminalAccountID()
        for account in try env.store.load() {
            print(pad(account.id, 76) + pad(account.label, 14) + pad(account.email, 32) + pad(account.plan, 14)
                  + (account.id == terminalID ? "● terminal" : account.status.rawValue))
        }
    }

    static func stats(_ env: CoreEnvironment, showUnknown: Bool) async throws {
        let index = try env.makeIndex()
        let started = Date()
        let progress = try await index.refresh { p in
            FileHandle.standardError.write(Data("\rindexing \(p.filesDone)/\(p.filesTotal)".utf8))
        }
        FileHandle.standardError.write(Data(String(format: "\rindexed %d files in %.1fs\n", progress.filesTotal,
                                                   Date().timeIntervalSince(started)).utf8))
        let s = try await index.stats(now: env.now.now(), calendar: .current)
        print("today \(Format.money(micros: s.todayMicros))  ·  7 days \(Format.money(micros: s.last7dMicros))  ·  30 days \(Format.money(micros: s.last30dMicros))")
        print("\(Format.tokens(s.todayTokens)) tok · cache hit \(Int((s.cacheHitRate * 100).rounded()))% · \(s.todayMessages) msgs · \(s.todaySessions) sessions")
        print("model mix: " + s.modelMix.map { "\($0.family) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: " · "))
        for project in s.topProjects { print("  " + pad(project.project, 40) + Format.money(micros: project.costMicros)) }
        let peak = max(s.hourly.map(\.costMicros).max() ?? 0, 1)
        let bars = Array("▁▂▃▄▅▆▇█")
        print("last 24h " + String(s.hourly.map { bars[Int(Double($0.costMicros) / Double(peak) * 7)] }))
        if showUnknown { print("unknown models: " + (try await index.unknownModels()).joined(separator: ", ")) }
    }

    static func reindex(_ env: CoreEnvironment) async throws {
        let index = try env.makeIndex()
        try await index.reset()
        try await stats(env, showUnknown: true)
    }

    static func login(_ env: CoreEnvironment, email: String?) async throws {
        guard let claude = env.locateClaude(customPath: nil) else {
            throw LoginError.failed(exitCode: 127)
        }
        print("Finish signing in in your browser…")
        let account = try await env.makeLoginFlow(claude: claude).addAccount(method: email.map(LoginMethod.email) ?? .google)
        print("✓ Added \(account.email) · \(account.plan)")
    }
}
```

- [ ] **Step 6: Write the independent spend check**

`scripts/verify_spend.py` (no third-party modules; mirrors spec §9 independently of the Swift code):

```python
#!/usr/bin/env python3
"""Recompute today's API-equivalent spend from ~/.claude/projects to cross-check `claude-usage-cli stats`."""
import datetime
import glob
import json
import os

PRICES = [  # prefix, input, output, cache read  ($/MTok, spec §9)
    ("claude-fable-5-1", 10, 50, 0.25), ("claude-fable-5", 10, 50, 1.00),
    ("claude-opus-5-5", 4, 20, 0.20), ("claude-opus-5", 5, 25, 0.50), ("claude-opus-4-8", 5, 25, 0.50),
    ("claude-opus-4-7", 5, 25, 0.50), ("claude-opus-4-6", 5, 25, 0.50),
    ("claude-sonnet-5-5", 2, 10, 0.20), ("claude-sonnet-5", 2, 10, 0.20), ("claude-sonnet-4-6", 3, 15, 0.30),
    ("claude-haiku-4-5", 1, 5, 0.10),
]


def price(model):
    matches = [p for p in PRICES if model.startswith(p[0])]
    return max(matches, key=lambda p: len(p[0])) if matches else None


def main():
    start = datetime.datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    seen, total = set(), 0.0
    files = sorted(glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True))
    for path in files:
        with open(path, "rb") as handle:
            for raw in handle:
                if b'"type":"assistant"' not in raw or not raw.endswith(b"\n"):
                    continue
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                message = line.get("message") or {}
                mid, model, usage = message.get("id"), message.get("model"), message.get("usage")
                if line.get("type") != "assistant" or not mid or not model or model == "<synthetic>" or not usage:
                    continue
                if mid in seen:
                    continue
                seen.add(mid)
                ts = datetime.datetime.fromisoformat(line["timestamp"].replace("Z", "+00:00")).timestamp()
                if (ts // 3600) * 3600 < start:
                    continue
                p = price(model)
                if not p:
                    continue
                detail = usage.get("cache_creation")
                cw1h = (detail or {}).get("ephemeral_1h_input_tokens") or 0
                cw5m = (detail or {}).get("ephemeral_5m_input_tokens") or 0 if detail else usage.get("cache_creation_input_tokens") or 0
                cost = ((usage.get("input_tokens") or 0) * p[1] + (usage.get("output_tokens") or 0) * p[2]
                        + (usage.get("cache_read_input_tokens") or 0) * p[3] + cw5m * p[1] * 1.25 + cw1h * p[1] * 2.0)
                if usage.get("speed") == "fast":
                    cost *= 2
                total += cost
    print(f"today ${total / 1e6:.2f}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 7: Verify against real data (read-only)**

Run:

```bash
swift build -c release
time .build/release/claude-usage-cli --read-only status
.build/release/claude-usage-cli --read-only accounts
time .build/release/claude-usage-cli --read-only stats --unknown-models
python3 scripts/verify_spend.py
time .build/release/claude-usage-cli --read-only stats
```

Expected:
- `status` lists Jeff's terminal account (`you@work.example  Max 20x  ● terminal  [ok]`) with three rows — `Session · 5h`, `Week · all models`, `Week · Fable` — and percentages that match `/usage` in Claude Code. No token appears anywhere in the output.
- First `stats` run indexes all transcripts (several GB) in under 2 minutes and prints today/7 days/30 days; `unknown models` lists only non-Claude ids (e.g. `gpt_image_2_5`).
- `verify_spend.py`'s `today $X` is within 1 % of the CLI's `today` (the two runs are seconds apart; re-run both if a session is active).
- The second `stats` run finishes in under 1 s of index time.

Record the timings and the two "today" numbers in `docs/notes/spike.md` under a new `## Real-data check (Task 13)` heading. If `status` shows `[needsSignIn]` for the terminal account, stop and report — do not try to log in.

- [ ] **Step 8: Commit**

```bash
git add Sources Tests scripts/verify_spend.py docs/notes/spike.md
git commit -m "feat(cli): composition root and claude-usage-cli; verify spend against transcripts"
```

---

### Task 14: Presentation logic and the app shell

**Files:**
- Create: `Sources/UsageCore/Presentation.swift`
- Test: `Tests/UsageCoreTests/PresentationTests.swift`
- Create: `Sources/ClaudeUsage/Theme.swift`, `Sources/ClaudeUsage/AppModel.swift`, `Sources/ClaudeUsage/RootView.swift`, `Sources/ClaudeUsage/Notifications.swift`, `Sources/ClaudeUsage/UsageView.swift` (minimal; Task 15 replaces it)
- Modify: `Sources/ClaudeUsage/App.swift` (replace the bootstrap)

**Interfaces:**
- Consumes: `CoreEnvironment` (Task 13), `Poller`, `AccountRefreshState`, `StateCache`, `Notifier`, `NotifierState`, `NotificationEvent` (Task 12), `TranscriptIndex`, `IndexProgress`, `SpendStats`, `HourCost` (Tasks 6–7), `Recommender`, `RecommendationCandidate`, `Format`, `UsageLevel` (Task 4), `LoginMethod`, `LoginError` (Task 11), `SwitchError` (Task 10), `PricingTable.monthlyTotal` (Task 5).
- Produces (UsageCore, public):
  - `enum MenuBarMode: String, Codable, Sendable, CaseIterable { case session, week, both, icon }`; `enum ThemeStyle: String, Codable, Sendable, CaseIterable { case cli, claude }`; `enum Appearance: String, Codable, Sendable, CaseIterable { case system, dark, light }`.
  - `struct AppSettings: Codable, Sendable, Equatable` — `refreshMinutes = 5`, `menuBarMode = .both`, `notifyAt80 = true`, `notifyAt95 = true`, `notifyOnReset = false`, `launchAtLogin = false`, `style = .cli`, `appearance = .system`, `claudePath: String? = nil`; `init()`; tolerant `init(from:)` (missing keys → defaults); `static func load(from: URL) -> AppSettings`; `func save(to: URL) throws`; `var thresholds: [Int]`.
  - `enum MenuBarTitle { static func text(mode: MenuBarMode, snapshot: UsageSnapshot?, status: AccountStatus?) -> String }`.
  - `struct SpendSummary: Sendable, Equatable { dailyAverage7dMicros: Int64; todayVsAverage: Double?; peakHour: HourCost?; planMultiple: Double?; static func from(_ stats: SpendStats, monthlyPlanTotal: Double) -> SpendSummary }`.
  - `enum AccountPalette { static let hex: [UInt32]; static func hex(for index: Int) -> UInt32 }`; `enum StatusText { static func of(_ status: AccountStatus?) -> String }`.
- Produces (ClaudeUsage target, internal):
  - `enum Tok` (colors: `bg, surface, surface2, surface3, text, text2, muted, faint, border, borderStrong, track, claude, claudeStrong, claudeTint, success, warning, error, suggestion`; `static func level(_: UsageLevel) -> Color`; `static func avatar(_ index: Int) -> Color`), `enum Typo { static func ui(_ style: ThemeStyle, size: CGFloat = 11, weight: Font.Weight = .regular) -> Font; static func num(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font; static func serif(size: CGFloat = 18) -> Font }`, `EnvironmentValues.themeStyle: ThemeStyle`, `Appearance.colorScheme: ColorScheme?`.
  - `protocol NotificationPosting: Sendable { func post(_ events: [NotificationEvent]) }`, `struct NoopNotificationPoster`, `enum NotificationPosterFactory { static func make() -> any NotificationPosting }`.
  - `enum Route: Equatable { case usage, settings, addAccount }`; `enum AddAccountState: Equatable { case idle, waiting(LoginMethod), success(email: String, plan: String), failed(String) }`.
  - `@MainActor @Observable final class AppModel` — state: `accounts`, `states`, `terminalID`, `selectedID`, `stats`, `indexProgress`, `preferredModel`, `route`, `addState`, `addPrefillEmail`, `toast`, `isRefreshing`, `settings` (saved on change; changing `refreshMinutes` restarts the loop); derived: `displayedAccount`, `displayedSnapshot`, `terminalAccount`, `menuBarTitle`, `bestAccountID`, `monthlyPlanTotal`, `spendSummary`, `func account(id:) -> Account?`, `func state(for:) -> AccountRefreshState?`, `func headroomLine(for: Account) -> String`; actions: `start()`, `refreshNow(force:) async`, `refreshStats() async`, `popoverOpened()`, `useInTerminal(_ id: String)`, `addAccount(_ method: LoginMethod)`, `cancelAddAccount()`, `signInAgain(_ account: Account)`, `rename(_ id: String, to: String)`, `remove(_ id: String)`, `showToast(_ text: String)`, `quit()`.
  - `struct RootView: View` (routes; toast overlay; calls `popoverOpened()` on appear).

- [ ] **Step 1: Write the failing presentation tests**

`Tests/UsageCoreTests/PresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import UsageCore

struct PresentationTests {
    @Test func menuBarTitles() {
        let s = UsageSnapshot.fake(session: 25, weekly: 54, fable: 64)
        #expect(MenuBarTitle.text(mode: .both, snapshot: s, status: .ok) == "✻ 25% · 64%")
        #expect(MenuBarTitle.text(mode: .session, snapshot: s, status: .ok) == "✻ 25%")
        #expect(MenuBarTitle.text(mode: .week, snapshot: s, status: .ok) == "✻ 64%")
        #expect(MenuBarTitle.text(mode: .icon, snapshot: s, status: .ok) == "✻")
        #expect(MenuBarTitle.text(mode: .both, snapshot: nil, status: nil) == "✻ —")
    }

    @Test func titleShowsBangWhenTerminalNeedsSignIn() {
        #expect(MenuBarTitle.text(mode: .both, snapshot: .fake(), status: .needsSignIn) == "✻ !")
    }

    @Test func settingsDefaultsAndTolerantDecoding() throws {
        let s = AppSettings()
        #expect(s.refreshMinutes == 5 && s.menuBarMode == .both && s.style == .cli && s.appearance == .system)
        #expect(s.thresholds == [80, 95])
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"refreshMinutes":15,"notifyAt80":false}"#.utf8))
        #expect(partial.refreshMinutes == 15)
        #expect(partial.thresholds == [95])
        #expect(partial.menuBarMode == .both)
        let dir = try TempDir()
        try partial.save(to: dir.file("settings.json"))
        #expect(AppSettings.load(from: dir.file("settings.json")) == partial)
        #expect(AppSettings.load(from: dir.file("missing.json")) == AppSettings())
    }

    @Test func spendSummary() {
        var stats = SpendStats.empty
        stats.todayMicros = 48_200_000
        stats.last7dMicros = 286_400_000
        stats.last30dMicros = 1_140_000_000
        stats.hourly = [HourCost(hourStart: Date(timeIntervalSince1970: 0), costMicros: 1),
                        HourCost(hourStart: Date(timeIntervalSince1970: 3_600), costMicros: 6_100_000)]
        let summary = SpendSummary.from(stats, monthlyPlanTotal: 200)
        #expect(summary.dailyAverage7dMicros == 40_914_285)
        #expect(abs(summary.todayVsAverage! - (48.2 / ((286.4 - 48.2) / 6) - 1)) < 1e-9)
        #expect(summary.peakHour?.costMicros == 6_100_000)
        #expect(abs(summary.planMultiple! - 5.7) < 1e-9)
        #expect(SpendSummary.from(.empty, monthlyPlanTotal: 0).planMultiple == nil)
        #expect(SpendSummary.from(.empty, monthlyPlanTotal: 0).todayVsAverage == nil)
    }

    @Test func paletteWrapsAndStatusText() {
        #expect(AccountPalette.hex(for: 0) == 0xc96442)
        #expect(AccountPalette.hex(for: 6) == AccountPalette.hex(for: 0))
        #expect(StatusText.of(.needsSignIn) == "needs sign-in")
        #expect(StatusText.of(.ok) == "token ok")
        #expect(StatusText.of(nil) == "not checked")
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --filter PresentationTests`
Expected: build errors — `cannot find 'MenuBarTitle' in scope`.

- [ ] **Step 3: Implement presentation logic**

`Sources/UsageCore/Presentation.swift`:

```swift
import Foundation

public enum MenuBarMode: String, Codable, Sendable, CaseIterable {
    case session, week, both, icon
}

public enum ThemeStyle: String, Codable, Sendable, CaseIterable {
    /// Monospaced everywhere, like the Claude Code CLI.
    case cli
    /// System sans with monospaced numbers, like claude.ai.
    case claude
}

public enum Appearance: String, Codable, Sendable, CaseIterable {
    case system, dark, light
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var refreshMinutes = 5
    public var menuBarMode = MenuBarMode.both
    public var notifyAt80 = true
    public var notifyAt95 = true
    public var notifyOnReset = false
    public var launchAtLogin = false
    public var style = ThemeStyle.cli
    public var appearance = Appearance.system
    public var claudePath: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case refreshMinutes, menuBarMode, notifyAt80, notifyAt95, notifyOnReset, launchAtLogin, style, appearance, claudePath
    }

    /// Missing keys fall back to defaults, so older settings files keep working.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        menuBarMode = try c.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? d.menuBarMode
        notifyAt80 = try c.decodeIfPresent(Bool.self, forKey: .notifyAt80) ?? d.notifyAt80
        notifyAt95 = try c.decodeIfPresent(Bool.self, forKey: .notifyAt95) ?? d.notifyAt95
        notifyOnReset = try c.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? d.notifyOnReset
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        style = try c.decodeIfPresent(ThemeStyle.self, forKey: .style) ?? d.style
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
    }

    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public var thresholds: [Int] { (notifyAt80 ? [80] : []) + (notifyAt95 ? [95] : []) }
}

public enum MenuBarTitle {
    public static func text(mode: MenuBarMode, snapshot: UsageSnapshot?, status: AccountStatus?) -> String {
        if status == .needsSignIn { return "✻ !" }
        if mode == .icon { return "✻" }
        guard let snapshot else { return "✻ —" }
        let session = snapshot.session.map { Format.percent($0.percent) } ?? "—"
        let week = snapshot.highestWeekly.map { Format.percent($0.percent) } ?? "—"
        switch mode {
        case .session: return "✻ \(session)"
        case .week: return "✻ \(week)"
        case .both, .icon: return "✻ \(session) · \(week)"
        }
    }
}

public struct SpendSummary: Sendable, Equatable {
    public var dailyAverage7dMicros: Int64
    /// Today versus the average of the six previous days (0.18 = +18 %); nil without history.
    public var todayVsAverage: Double?
    public var peakHour: HourCost?
    /// 30-day API-equivalent spend divided by the summed monthly price of the subscribed plans.
    public var planMultiple: Double?

    public static func from(_ stats: SpendStats, monthlyPlanTotal: Double) -> SpendSummary {
        let previousAverage = Double(stats.last7dMicros - stats.todayMicros) / 6
        return SpendSummary(
            dailyAverage7dMicros: stats.last7dMicros / 7,
            todayVsAverage: previousAverage > 0 ? Double(stats.todayMicros) / previousAverage - 1 : nil,
            peakHour: stats.hourly.filter { $0.costMicros > 0 }.max { $0.costMicros < $1.costMicros },
            planMultiple: monthlyPlanTotal > 0 ? Double(stats.last30dMicros) / 1_000_000 / monthlyPlanTotal : nil)
    }
}

public enum AccountPalette {
    /// clay, olive, slate blue, plum, teal, sand
    public static let hex: [UInt32] = [0xc96442, 0x7d8a4e, 0x5b7fa6, 0x8a5a83, 0x4f8a8b, 0xb08a4f]

    public static func hex(for index: Int) -> UInt32 {
        hex[((index % hex.count) + hex.count) % hex.count]
    }
}

public enum StatusText {
    public static func of(_ status: AccountStatus?) -> String {
        switch status {
        case .ok: return "token ok"
        case .needsSignIn: return "needs sign-in"
        case .offline: return "offline"
        case .rateLimited: return "rate-limited"
        case nil: return "not checked"
        }
    }
}
```

- [ ] **Step 4: Run the presentation tests**

Run: `swift test --filter PresentationTests`
Expected: all pass.

- [ ] **Step 5: Theme and notification plumbing (app target)**

`Sources/ClaudeUsage/Theme.swift`:

```swift
import AppKit
import SwiftUI
import UsageCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Tokens mirrored from prototypes/tokens.css (light / dark).
enum Tok {
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }

    static let bg = dynamic(light: 0xfaf9f5, dark: 0x262624)
    static let surface = dynamic(light: 0xf5f4ed, dark: 0x1f1e1d)
    static let surface2 = dynamic(light: 0xf0eee6, dark: 0x30302e)
    static let surface3 = dynamic(light: 0xe8e6dc, dark: 0x3a3936)
    static let text = dynamic(light: 0x141413, dark: 0xfaf9f5)
    static let text2 = dynamic(light: 0x3d3d3a, dark: 0xc2c0b6)
    static let muted = dynamic(light: 0x73726c, dark: 0x9c9a92)
    static let faint = dynamic(light: 0xa3a19a, dark: 0x6b6a65)
    static let border = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.12, darkAlpha: 0.12)
    static let borderStrong = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.22, darkAlpha: 0.22)
    static let track = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.08, darkAlpha: 0.10)
    static let claude = dynamic(light: 0xc96442, dark: 0xd97757)
    static let claudeStrong = Color(nsColor: NSColor(hex: 0xc96442))
    static let claudeTint = dynamic(light: 0xc96442, dark: 0xd97757, lightAlpha: 0.10, darkAlpha: 0.14)
    static let success = dynamic(light: 0x2f8f46, dark: 0x4eba65)
    static let warning = dynamic(light: 0xb7791f, dark: 0xe5a83b)
    static let error = dynamic(light: 0xc4314b, dark: 0xff6b80)
    static let suggestion = dynamic(light: 0x5865c9, dark: 0xb1b9f9)

    static func level(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: return claude
        case .warn: return warning
        case .critical: return error
        }
    }

    static func avatar(_ index: Int) -> Color { Color(nsColor: NSColor(hex: AccountPalette.hex(for: index))) }
}

enum Typo {
    static func ui(_ style: ThemeStyle, size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        style == .cli ? .system(size: size, weight: weight, design: .monospaced) : .system(size: size + 1, weight: weight)
    }

    static func num(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }

    static func serif(size: CGFloat = 18) -> Font { .system(size: size, design: .serif) }
}

private struct ThemeStyleKey: EnvironmentKey {
    static let defaultValue = ThemeStyle.cli
}

extension EnvironmentValues {
    var themeStyle: ThemeStyle {
        get { self[ThemeStyleKey.self] }
        set { self[ThemeStyleKey.self] = newValue }
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
```

`Sources/ClaudeUsage/Notifications.swift`:

```swift
import Foundation
import UsageCore

protocol NotificationPosting: Sendable {
    func post(_ events: [NotificationEvent])
}

struct NoopNotificationPoster: NotificationPosting {
    func post(_ events: [NotificationEvent]) {}
}

enum NotificationPosterFactory {
    /// Task 17 returns the UserNotifications poster when running from the .app bundle.
    static func make() -> any NotificationPosting { NoopNotificationPoster() }
}
```

- [ ] **Step 6: The app model**

`Sources/ClaudeUsage/AppModel.swift`:

```swift
import AppKit
import Observation
import SwiftUI
import UsageCore

enum Route: Equatable {
    case usage, settings, addAccount
}

enum AddAccountState: Equatable {
    case idle
    case waiting(LoginMethod)
    case success(email: String, plan: String)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    let env: CoreEnvironment
    @ObservationIgnored private let poster: any NotificationPosting
    @ObservationIgnored private let poller: Poller
    @ObservationIgnored private var index: TranscriptIndex?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var notifierState: NotifierState

    var accounts: [Account] = []
    var states: [String: AccountRefreshState]
    var terminalID: String?
    var selectedID: String?
    var stats = SpendStats.empty
    var indexProgress: IndexProgress?
    var preferredModel: String?
    var route = Route.usage
    var addState = AddAccountState.idle
    var addPrefillEmail = ""
    var toast: String?
    var isRefreshing = false
    var settings: AppSettings {
        didSet {
            try? settings.save(to: env.paths.settingsFile)
            if oldValue.refreshMinutes != settings.refreshMinutes { restartLoop() }
        }
    }

    init(env: CoreEnvironment, poster: any NotificationPosting) {
        self.env = env
        self.poster = poster
        let cached = StateCache.load(from: env.paths.snapshotsCache)
        self.states = cached
        self.poller = Poller(api: env.api, credentials: env.credentials, now: env.now, initial: cached)
        self.settings = AppSettings.load(from: env.paths.settingsFile)
        self.notifierState = NotifierState.load(from: env.paths.notifierState)
    }

    // MARK: Derived

    func account(id: String) -> Account? { accounts.first { $0.id == id } }
    func state(for id: String) -> AccountRefreshState? { states[id] }
    var terminalAccount: Account? { terminalID.flatMap(account(id:)) }
    var displayedAccount: Account? { selectedID.flatMap(account(id:)) ?? terminalAccount ?? accounts.first }
    var displayedSnapshot: UsageSnapshot? { displayedAccount.flatMap { states[$0.id]?.snapshot } }

    var menuBarTitle: String {
        MenuBarTitle.text(mode: settings.menuBarMode, snapshot: terminalID.flatMap { states[$0]?.snapshot },
                          status: terminalID.flatMap { states[$0]?.status })
    }

    var bestAccountID: String? {
        Recommender.best(accounts.map { account in
            RecommendationCandidate(accountID: account.id,
                                    isAvailable: (states[account.id]?.status ?? .ok) != .needsSignIn,
                                    isTerminal: account.id == terminalID, snapshot: states[account.id]?.snapshot)
        }, preferredModel: preferredModel)
    }

    var monthlyPlanTotal: Double { env.pricing.monthlyTotal(for: accounts.map(\.plan)) }
    var spendSummary: SpendSummary { SpendSummary.from(stats, monthlyPlanTotal: monthlyPlanTotal) }

    /// "week 12% · Fable 20%"
    func headroomLine(for account: Account) -> String {
        guard let snapshot = states[account.id]?.snapshot else { return "" }
        var parts: [String] = []
        if let week = snapshot.limits.first(where: { $0.kind == "weekly_all" }) { parts.append("week \(Format.percent(week.percent))") }
        if let model = preferredModel,
           let scoped = snapshot.limits.first(where: { $0.kind == "weekly_scoped" && $0.modelName?.caseInsensitiveCompare(model) == .orderedSame }) {
            parts.append("\(model) \(Format.percent(scoped.percent))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Lifecycle

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        reloadAccounts()
        restartLoop()
    }

    private func reloadAccounts() {
        _ = try? TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        accounts = (try? env.store.load()) ?? []
        terminalID = env.terminalAccountID()
    }

    private func restartLoop() {
        loop?.cancel()
        let seconds = Double(settings.refreshMinutes) * 60
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow(force: false)
                await self?.refreshStats()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func popoverOpened() {
        let last = terminalID.flatMap { states[$0]?.lastSuccess }
        if Poller.shouldRefreshOnOpen(lastSuccess: last, now: env.now.now()) {
            Task { await refreshNow(force: false) }
        }
    }

    func refreshNow(force: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        reloadAccounts()
        states = await poller.refresh(accounts: accounts, terminalID: terminalID, force: force)
        try? StateCache.save(states, to: env.paths.snapshotsCache)
        for account in accounts {
            guard let status = states[account.id]?.status, status != account.status else { continue }
            try? env.store.update(id: account.id) { $0.status = status }
        }
        accounts = (try? env.store.load()) ?? accounts
        notify()
    }

    /// Indexes transcripts in batches so the first multi-GB run shows partial totals and never blocks the UI.
    func refreshStats() async {
        do {
            if index == nil { index = try env.makeIndex() }
            guard let index else { return }
            while true {
                let progress = try await index.refresh(limit: 200)
                indexProgress = progress.isComplete ? nil : progress
                stats = try await index.stats(now: env.now.now(), calendar: .current)
                if progress.isComplete { break }
            }
            preferredModel = try await index.topModelFamily(since: env.now.now().addingTimeInterval(-7 * 86_400))
        } catch {
            indexProgress = nil
            showToast("Spend stats unavailable: \(error.localizedDescription)")
        }
    }

    private func notify() {
        let notifier = Notifier(thresholds: settings.thresholds, notifyOnReset: settings.notifyOnReset)
        var events: [NotificationEvent] = []
        for account in accounts {
            guard let state = states[account.id], state.status == .ok, let snapshot = state.snapshot else { continue }
            events += notifier.evaluate(accountID: account.id, label: account.label, snapshot: snapshot,
                                        state: &notifierState, now: env.now.now())
        }
        try? notifierState.save(to: env.paths.notifierState)
        if !events.isEmpty { poster.post(events) }
    }

    // MARK: Actions

    func useInTerminal(_ id: String) {
        do {
            let result = try env.switcher.switchTerminal(to: id)
            reloadAccounts()
            showToast("✻ Terminal switched to \(account(id: result.toID)?.label ?? "account") — new `claude` sessions use it")
            Task { await refreshNow(force: true) }
        } catch SwitchError.needsSignIn {
            showToast("Sign in to that account again first")
        } catch {
            showToast("Couldn't switch: \(error)")
        }
    }

    func addAccount(_ method: LoginMethod) {
        guard let claude = env.locateClaude(customPath: settings.claudePath) else {
            addState = .failed("Claude Code not found — set its path in Settings")
            return
        }
        addState = .waiting(method)
        let flow = env.makeLoginFlow(claude: claude)
        loginTask = Task { [weak self] in
            do {
                let account = try await flow.addAccount(method: method)
                guard let self else { return }
                self.addState = .success(email: account.email, plan: account.plan)
                self.reloadAccounts()
                await self.refreshNow(force: true)
                try? await Task.sleep(for: .seconds(1.5))
                if case .success = self.addState {
                    self.addState = .idle
                    self.route = .settings
                }
            } catch LoginError.cancelled {
                self?.addState = .idle
            } catch {
                self?.addState = .failed(Self.message(for: error))
            }
        }
    }

    func cancelAddAccount() {
        loginTask?.cancel()
        loginTask = nil
        addState = .idle
    }

    func signInAgain(_ account: Account) {
        addPrefillEmail = account.email
        addState = .idle
        route = .addAccount
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? env.store.update(id: id) { $0.label = trimmed }
        accounts = (try? env.store.load()) ?? accounts
    }

    func remove(_ id: String) {
        guard id != terminalID else {
            showToast("Switch the terminal to another account first")
            return
        }
        try? env.store.remove(id: id)
        states[id] = nil
        if selectedID == id { selectedID = nil }
        accounts = (try? env.store.load()) ?? accounts
    }

    func showToast(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.toast == text { self?.toast = nil }
        }
    }

    func quit() { NSApplication.shared.terminate(nil) }

    nonisolated static func message(for error: any Error) -> String {
        switch error {
        case LoginError.failed(let code): return "Sign-in failed (claude exited with \(code))"
        case LoginError.timedOut: return "Sign-in timed out after 10 minutes"
        case LoginError.noCredentials: return "Claude Code didn't save a login — try again"
        default: return "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 7: Root view, minimal usage view, app entry point**

`Sources/ClaudeUsage/RootView.swift`:

```swift
import SwiftUI
import UsageCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.route {
            case .usage: UsageView()
            default: UsageView()   // Task 16 adds the Settings and Add-account routes
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 640)
        .background(Tok.bg)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tok.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface3))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.borderStrong, lineWidth: 0.5))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .onAppear { model.popoverOpened() }
    }
}
```

`Sources/ClaudeUsage/UsageView.swift` (minimal; Task 15 replaces the whole file):

```swift
import SwiftUI
import UsageCore

struct UsageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.displayedAccount.map { "\($0.label) · \($0.email)" } ?? "No account yet")
            ForEach(model.displayedSnapshot?.limits ?? []) { limit in
                Text("\(limit.title)  \(Format.percent(limit.percent))")
            }
        }
        .font(Typo.ui(.cli))
        .foregroundStyle(Tok.text)
        .padding(12)
    }
}
```

Replace `Sources/ClaudeUsage/App.swift`:

```swift
import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @State private var model: AppModel

    init() {
        let env: CoreEnvironment
        do { env = try CoreEnvironment.live() } catch { fatalError("Cannot create the Application Support folder: \(error)") }
        let model = AppModel(env: env, poster: NotificationPosterFactory.make())
        _model = State(initialValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(model)
                .environment(\.themeStyle, model.settings.style)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        } label: {
            Text(model.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 8: Build, test and smoke-run**

Run:

```bash
swift build && swift test
swift run ClaudeUsage & APP=$!; sleep 10; kill -0 $APP && echo "still running"; kill $APP
```

Expected: build and all tests pass; "still running" is printed (no crash at launch); the menu bar shows `✻ <session>% · <week>%` for Jeff's terminal account within ~10 s (look at the menu bar or run `screencapture -x -R0,0,1800,30 /tmp/cu-menubar.png` and view it). Do not click anything in the popover.

- [ ] **Step 9: Commit**

```bash
git add Sources Tests
git commit -m "feat(app): menu bar shell, Claude theme tokens and app model"
```

---

### Task 15: Usage view

**Files:**
- Create: `Sources/ClaudeUsage/Components.swift`, `Sources/ClaudeUsage/LimitsSection.swift`, `Sources/ClaudeUsage/StatsSection.swift`
- Modify: `Sources/ClaudeUsage/UsageView.swift` (replace the whole file)

**Interfaces:**
- Consumes: `AppModel` API, `Tok`, `Typo`, `themeStyle`, `Route` (Task 14); `Format`, `PaceCalculator`, `UsageLevel` (Task 4); `StatusText`, `SpendSummary` (Task 14); `HourCost`, `ModelShare`, `ProjectCost` (Task 7).
- Produces (used by Task 16): `struct SectionLabel(text: String, trailing: String? = nil)`, `struct Hairline`, `struct AvatarView(account: Account, size: CGFloat = 22)`, `struct Badge(text: String, accent: Bool = false)`, `struct TerminalTag`, `struct UsageBar(percent: Double, paceFraction: Double?, level: UsageLevel, dimmed: Bool = false)`, `struct ClaudeButtonStyle: ButtonStyle (kind: .primary | .secondary | .ghost, fullWidth: Bool = false)`, `struct IconButton(systemName: String, help: String, action: () -> Void)`, `struct Segmented<Value: Hashable>(options: [(Value, String)], selection: Binding<Value>)`, `struct Spinner`.

Visual target: `prototypes/menubar.html` and `prototypes/shots/menubar-usage-dark-cli-stats.png` (header, chips, limits with pace marker and `⎿` line, "best account now" callout, "this mac · api-equivalent spend" tiles, tokens line, last-24h bars with peak, model mix, top projects, 7d by surface, footer).

- [ ] **Step 1: Shared components**

`Sources/ClaudeUsage/Components.swift`:

```swift
import SwiftUI
import UsageCore

struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(Typo.ui(style, size: 10))
        .foregroundStyle(Tok.muted)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Tok.border).frame(height: 0.5) }
}

struct AvatarView: View {
    let account: Account
    var size: CGFloat = 22

    var body: some View {
        Text(String(account.label.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Tok.avatar(account.colorIndex)))
    }
}

struct Badge: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(accent ? Tok.claude : Tok.text2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(accent ? Tok.claudeTint : Tok.surface2))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent ? Color.clear : Tok.border, lineWidth: 0.5))
    }
}

struct TerminalTag: View {
    var body: some View {
        Text("● terminal").font(.system(size: 10, design: .monospaced)).foregroundStyle(Tok.claude)
    }
}

struct UsageBar: View {
    let percent: Double
    let paceFraction: Double?
    let level: UsageLevel
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Tok.track)
                RoundedRectangle(cornerRadius: 3).fill(Tok.level(level))
                    .frame(width: width * min(max(percent, 0), 100) / 100)
                if let paceFraction {
                    Rectangle().fill(Tok.text2.opacity(0.7))
                        .frame(width: 1.5, height: 10)
                        .offset(x: min(max(width * paceFraction - 0.75, 0), width - 1.5))
                }
            }
        }
        .frame(height: 6)
        .opacity(dimmed ? 0.4 : 1)
    }
}

struct ClaudeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind = Kind.secondary
    var fullWidth = false
    @Environment(\.themeStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.ui(style, weight: kind == .primary ? .medium : .regular))
            .padding(.horizontal, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: fullWidth ? 30 : 24)
            .foregroundStyle(kind == .primary ? Color.white : (kind == .ghost ? Tok.text2 : Tok.text))
            .background(RoundedRectangle(cornerRadius: 8).fill(background(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .secondary ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
            .contentShape(Rectangle())
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return Tok.claudeStrong.opacity(pressed ? 0.85 : 1)
        case .secondary: return pressed ? Tok.surface3 : Tok.surface2
        case .ghost: return pressed ? Tok.surface2 : Color.clear
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(Tok.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(Typo.ui(style, size: 10))
                        .foregroundStyle(selected ? Tok.text : Tok.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Tok.bg : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

/// The CLI's ✻ spinner.
struct Spinner: View {
    private let frames = ["✻", "✽", "✶", "✳"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(frames[Int(context.date.timeIntervalSinceReferenceDate * 4) % frames.count])
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tok.claude)
        }
    }
}
```

- [ ] **Step 2: Limits section**

`Sources/ClaudeUsage/LimitsSection.swift`:

```swift
import SwiftUI
import UsageCore

struct LimitsSection: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.state(for: account.id)
        let signedOut = state?.status == .needsSignIn
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "limits",
                         trailing: state.flatMap { $0.isStale ? "stale · \(StatusText.of($0.status))" : nil })
            if signedOut { SignInNotice(account: account) }
            if let limits = state?.snapshot?.limits, !limits.isEmpty {
                ForEach(limits) { limit in LimitRow(limit: limit, dimmed: signedOut) }
            } else if !signedOut {
                HStack(spacing: 6) {
                    Spinner()
                    Text("loading limits…").foregroundStyle(Tok.muted)
                }
            }
        }
        .padding(12)
    }
}

struct LimitRow: View {
    let limit: UsageLimit
    let dimmed: Bool
    @Environment(\.themeStyle) private var style

    var body: some View {
        let now = Date.now
        let pace = PaceCalculator.pace(for: limit, now: now)
        let level = UsageLevel.of(percent: limit.percent)
        let paceText = Format.paceLine(pace, percent: limit.percent, calendar: .current)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).foregroundStyle(Tok.text)
                Spacer()
                Text(Format.percent(limit.percent))
                    .font(Typo.num(weight: .medium))
                    .foregroundStyle(dimmed ? Tok.muted : Tok.level(level))
            }
            UsageBar(percent: limit.percent, paceFraction: pace.elapsedFraction, level: level, dimmed: dimmed)
            HStack(spacing: 4) {
                Text("⎿").foregroundStyle(Tok.faint)
                Text(Format.resetText(for: limit, now: now, calendar: .current)).foregroundStyle(Tok.muted)
                if !paceText.isEmpty {
                    Text("·").foregroundStyle(Tok.faint)
                    Text(paceText).foregroundStyle(paceColor(pace))
                }
            }
            .font(Typo.ui(style, size: 10))
            .lineLimit(1)
        }
    }

    private func paceColor(_ pace: Pace) -> Color {
        if case .ahead(_, let hit) = pace.status { return hit == nil ? Tok.warning : Tok.error }
        return Tok.muted
    }
}

struct SignInNotice: View {
    let account: Account
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("Session expired — sign in again").foregroundStyle(Tok.error)
            Spacer()
            Button("Sign in") { model.signInAgain(account) }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

struct BestAccountCallout: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "best account now")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Text("❯ ").foregroundStyle(Tok.claude))\(Text(account.label).fontWeight(.semibold)) has the most headroom")
                    Text(model.headroomLine(for: account))
                        .font(Typo.ui(style, size: 10))
                        .foregroundStyle(Tok.muted)
                }
                Spacer()
                Button("Use in terminal") { model.useInTerminal(account.id) }
                    .buttonStyle(ClaudeButtonStyle(kind: .primary))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.claudeTint))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.claude.opacity(0.35), lineWidth: 0.5))
        }
        .padding(12)
    }
}
```

- [ ] **Step 3: Stats section**

`Sources/ClaudeUsage/StatsSection.swift`:

```swift
import SwiftUI
import UsageCore

struct StatsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        let s = model.stats
        let summary = model.spendSummary
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "this mac · api-equivalent spend")
                HStack {
                    Text("estimated from local transcripts")
                    Spacer()
                    if let terminal = model.terminalAccount { Text("terminal: \(terminal.label)") }
                }
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.faint)
            }
            if let p = model.indexProgress {
                HStack(spacing: 6) {
                    Spinner()
                    Text("indexing \(p.filesDone) / \(p.filesTotal)").foregroundStyle(Tok.muted)
                }
                .font(Typo.ui(style, size: 10))
            }
            HStack(spacing: 6) {
                StatTile(title: "today", value: Format.money(micros: s.todayMicros),
                         note: summary.todayVsAverage.map { String(format: "%+.0f%% vs avg", $0 * 100) })
                StatTile(title: "7 days", value: Format.money(micros: s.last7dMicros),
                         note: "\(Format.money(micros: summary.dailyAverage7dMicros)) / day")
                StatTile(title: "30 days", value: Format.money(micros: s.last30dMicros),
                         note: summary.planMultiple.map { String(format: "%.1f× $%.0f plans", $0, model.monthlyPlanTotal) },
                         accentNote: true)
            }
            Text("\(Format.tokens(s.todayTokens)) tok · cache hit \(Int((s.cacheHitRate * 100).rounded()))% · \(s.todayMessages) msgs · \(s.todaySessions) sessions")
                .font(Typo.num(size: 10))
                .foregroundStyle(Tok.text2)
            HourlyChart(hours: s.hourly, peak: summary.peakHour)
            ModelMixBar(mix: s.modelMix)
            TopProjects(projects: s.topProjects)
            if let surfaces = model.displayedSnapshot?.surfaces, !surfaces.isEmpty {
                Text("7d by surface · " + surfaces.map { "\($0.displayName) \(Format.percent($0.percent))" }.joined(separator: " · "))
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.muted)
            }
        }
        .padding(12)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var note: String?
    var accentNote = false
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted)
            Text(value).font(Typo.num(size: 14, weight: .semibold)).foregroundStyle(Tok.text)
            Text(note ?? " ").font(Typo.ui(style, size: 10)).foregroundStyle(accentNote ? Tok.claude : Tok.muted).lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

struct HourlyChart: View {
    let hours: [HourCost]
    let peak: HourCost?

    var body: some View {
        let maxCost = max(hours.map(\.costMicros).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "last 24h", trailing: peak.map {
                "peak \(Format.clock($0.hourStart, calendar: .current)) · \(Format.money(micros: $0.costMicros))"
            })
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hours, id: \.hourStart) { hour in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(hour.costMicros > 0 ? Tok.claude.opacity(0.85) : Tok.track)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 36 * CGFloat(hour.costMicros) / CGFloat(maxCost)))
                        .help("\(Format.clock(hour.hourStart, calendar: .current)) · \(Format.money(micros: hour.costMicros))")
                }
            }
            .frame(height: 36, alignment: .bottom)
        }
    }
}

struct ModelMixBar: View {
    let mix: [ModelShare]
    @Environment(\.themeStyle) private var style

    static func color(_ family: String) -> Color {
        switch family {
        case "Fable": return Tok.claude
        case "Opus": return Tok.suggestion
        case "Sonnet": return Tok.success
        case "Haiku": return Tok.warning
        default: return Tok.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "model mix · today")
            if mix.isEmpty {
                Text("no usage today").font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(mix, id: \.family) { share in
                            Rectangle().fill(Self.color(share.family))
                                .frame(width: max(1, geo.size.width * share.fraction - 1))
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack(spacing: 8) {
                    ForEach(mix, id: \.family) { share in
                        HStack(spacing: 3) {
                            Circle().fill(Self.color(share.family)).frame(width: 5, height: 5)
                            Text("\(share.family) \(Int((share.fraction * 100).rounded()))%")
                        }
                    }
                }
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.text2)
            }
        }
    }
}

struct TopProjects: View {
    let projects: [ProjectCost]

    var body: some View {
        let top = max(projects.first?.costMicros ?? 1, 1)
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "top projects · today")
            ForEach(projects, id: \.project) { project in
                HStack(spacing: 8) {
                    Text(project.project).lineLimit(1).truncationMode(.head)
                    Spacer()
                    UsageBar(percent: 100 * Double(project.costMicros) / Double(top), paceFraction: nil, level: .normal)
                        .frame(width: 64)
                    Text(Format.money(micros: project.costMicros))
                        .font(Typo.num())
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Usage view**

Replace `Sources/ClaudeUsage/UsageView.swift`:

```swift
import SwiftUI
import UsageCore

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            if let account = model.displayedAccount {
                UsageHeader(account: account)
                AccountChips()
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LimitsSection(account: account)
                        if let bestID = model.bestAccountID, let best = model.account(id: bestID) {
                            Hairline()
                            BestAccountCallout(account: best)
                        }
                        Hairline()
                        StatsSection()
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Text("✻").font(.system(size: 22)).foregroundStyle(Tok.claude)
                    Text("No Claude account yet").foregroundStyle(Tok.text2)
                    Button("+ Add account") { model.route = .addAccount }
                        .buttonStyle(ClaudeButtonStyle(kind: .primary))
                }
                .padding(32)
            }
            Hairline()
            UsageFooter()
        }
        .font(Typo.ui(style))
        .foregroundStyle(Tok.text)
    }
}

struct UsageHeader: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(account: account, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.label).font(Typo.ui(style, size: 13, weight: .semibold))
                    Badge(text: account.plan)
                }
                HStack(spacing: 4) {
                    Text(account.email).foregroundStyle(Tok.muted).lineLimit(1).truncationMode(.middle)
                    if account.id == model.terminalID {
                        Text("·").foregroundStyle(Tok.faint)
                        TerminalTag()
                    }
                }
                .font(Typo.ui(style, size: 10))
            }
            Spacer(minLength: 4)
            Text(Format.updatedAgo(model.state(for: account.id)?.lastSuccess, now: .now)
                    .replacingOccurrences(of: "updated ", with: ""))
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.faint)
            IconButton(systemName: "arrow.clockwise", help: "Refresh") {
                Task { await model.refreshNow(force: true) }
            }
            IconButton(systemName: "slider.horizontal.3", help: "Settings") { model.route = .settings }
        }
        .padding(12)
    }
}

struct AccountChips: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.accounts) { account in
                    let selected = account.id == model.displayedAccount?.id
                    Button { model.selectedID = account.id } label: {
                        HStack(spacing: 5) {
                            AvatarView(account: account, size: 14)
                            Text(account.label).font(Typo.ui(style, size: 10))
                            if model.state(for: account.id)?.status == .needsSignIn {
                                Circle().fill(Tok.error).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? Tok.surface2 : Color.clear))
                        .overlay(Capsule().stroke(selected ? Tok.borderStrong : Tok.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 10)
    }
}

struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack {
            Text("Refreshes every \(model.settings.refreshMinutes) min").foregroundStyle(Tok.faint)
            Spacer()
            Button("Quit ⌘Q") { model.quit() }
                .buttonStyle(ClaudeButtonStyle(kind: .ghost))
                .keyboardShortcut("q")
        }
        .font(Typo.ui(style, size: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 5: Build, test and smoke-run**

Run:

```bash
swift build && swift test
swift run ClaudeUsage & APP=$!; sleep 10; kill -0 $APP && echo "still running"; kill $APP
```

Expected: build and tests pass; "still running". Compare a manual look of the popover with `prototypes/shots/menubar-usage-dark-cli-stats.png` only if Jeff is present — agents do not click.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsage
git commit -m "feat(app): usage popover — limits with pace, best account, spend stats"
```

---

### Task 16: Settings and Add-account views

**Files:**
- Create: `Sources/ClaudeUsage/SettingsView.swift`, `Sources/ClaudeUsage/AddAccountView.swift`, `Sources/ClaudeUsage/LaunchAtLogin.swift`
- Modify: `Sources/ClaudeUsage/RootView.swift` (route switch)

**Interfaces:**
- Consumes: `AppModel` API, `Route`, `AddAccountState` (Task 14); components from Task 15; `AppSettings`, `MenuBarMode`, `ThemeStyle`, `Appearance`, `StatusText` (Task 14); `LoginMethod` (Task 11).
- Produces: `struct SettingsView`, `struct AddAccountView`, `enum LaunchAtLogin { static var isEnabled: Bool; static func set(_ enabled: Bool) throws }`.

Visual target: `prototypes/shots/menubar-settings.png`, `menubar-add-account.png`, `menubar-add-waiting.png`, `menubar-add-done.png`.

- [ ] **Step 1: Launch at login**

`Sources/ClaudeUsage/LaunchAtLogin.swift`:

```swift
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Only works from the .app bundle (Task 17), not from `swift run`.
    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
```

- [ ] **Step 2: Settings view**

`Sources/ClaudeUsage/SettingsView.swift`:

```swift
import AppKit
import SwiftUI
import UsageCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Button { model.route = .usage } label: {
                    Text("‹ Settings").font(Typo.ui(style, size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AccountsSettings()
                    Hairline()
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "general")
                        SettingRow("Refresh every") {
                            Segmented(options: [(1, "1m"), (5, "5m"), (15, "15m")], selection: $model.settings.refreshMinutes)
                        }
                        SettingRow("Menu bar shows") {
                            Segmented(options: [(MenuBarMode.session, "Session"), (.week, "Week"), (.both, "Both"), (.icon, "Icon")],
                                      selection: $model.settings.menuBarMode)
                        }
                        SettingRow("Notify at 80%") { ClaudeToggle(isOn: $model.settings.notifyAt80) }
                        SettingRow("Notify at 95%") { ClaudeToggle(isOn: $model.settings.notifyAt95) }
                        SettingRow("Notify when limits reset") { ClaudeToggle(isOn: $model.settings.notifyOnReset) }
                        SettingRow("Launch at login") {
                            ClaudeToggle(isOn: Binding(
                                get: { model.settings.launchAtLogin },
                                set: { enabled in
                                    do {
                                        try LaunchAtLogin.set(enabled)
                                        model.settings.launchAtLogin = enabled
                                    } catch {
                                        model.showToast("Launch at login needs the app in /Applications")
                                    }
                                }))
                        }
                        SettingRow("Theme") {
                            Segmented(options: [(ThemeStyle.cli, "CLI"), (.claude, "Claude")], selection: $model.settings.style)
                        }
                        SettingRow("Appearance") {
                            Segmented(options: [(Appearance.system, "System"), (.dark, "Dark"), (.light, "Light")],
                                      selection: $model.settings.appearance)
                        }
                        SettingRow("Claude Code") {
                            Button(model.settings.claudePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "auto") {
                                pickClaudeBinary()
                            }
                            .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                            .help(model.env.locateClaude(customPath: model.settings.claudePath)?.path ?? "not found")
                        }
                    }
                    .padding(12)
                }
            }
            Hairline()
            Text("Tokens stay in your macOS Keychain · v0.1.0")
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .font(Typo.ui(style))
        .foregroundStyle(Tok.text)
    }

    private func pickClaudeBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the claude executable"
        if panel.runModal() == .OK, let url = panel.url { model.settings.claudePath = url.path }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control
        }
    }
}

struct ClaudeToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tok.claudeStrong)
            .labelsHidden()
    }
}

struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style
    @State private var hoveredID: String?
    @State private var renamingID: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "accounts", trailing: "\(model.accounts.filter { model.state(for: $0.id)?.status != .needsSignIn }.count) signed in")
            ForEach(model.accounts) { account in
                row(account)
            }
            Button("+ Add account") {
                model.addPrefillEmail = ""
                model.route = .addAccount
            }
            .buttonStyle(ClaudeButtonStyle(kind: .secondary, fullWidth: true))
        }
        .padding(12)
    }

    @ViewBuilder
    private func row(_ account: Account) -> some View {
        let isTerminal = account.id == model.terminalID
        let status = model.state(for: account.id)?.status
        HStack(spacing: 8) {
            AvatarView(account: account)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if renamingID == account.id {
                        TextField("Label", text: $draft)
                            .textFieldStyle(.plain)
                            .frame(width: 110)
                            .onSubmit {
                                model.rename(account.id, to: draft)
                                renamingID = nil
                            }
                    } else {
                        Text(account.label).fontWeight(.semibold)
                    }
                    Badge(text: account.plan)
                }
                Text(account.email).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted).lineLimit(1)
            }
            Spacer()
            if hoveredID == account.id && renamingID == nil {
                HStack(spacing: 4) {
                    if !isTerminal && status != .needsSignIn {
                        Button("Use in terminal") { model.useInTerminal(account.id) }
                            .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                    }
                    Button("Rename") {
                        draft = account.label
                        renamingID = account.id
                    }
                    .buttonStyle(ClaudeButtonStyle(kind: .ghost))
                    if !isTerminal {
                        Button("Remove") { model.remove(account.id) }
                            .buttonStyle(ClaudeButtonStyle(kind: .ghost))
                            .foregroundStyle(Tok.error)
                    }
                }
            } else if isTerminal {
                TerminalTag()
            } else if status == .needsSignIn {
                Button("needs sign-in") { model.signInAgain(account) }
                    .buttonStyle(.plain)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.error)
            } else {
                Text(StatusText.of(status)).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hoveredID == account.id ? Tok.surface2 : Color.clear))
        .onHover { inside in hoveredID = inside ? account.id : (hoveredID == account.id ? nil : hoveredID) }
    }
}
```

- [ ] **Step 3: Add-account view**

`Sources/ClaudeUsage/AddAccountView.swift`:

```swift
import SwiftUI
import UsageCore

struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style
    @State private var email = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.cancelAddAccount()
                    model.route = .settings
                } label: {
                    Text("‹ Back").font(Typo.ui(style, size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(12)
            Hairline()
            VStack(spacing: 12) {
                Text("✻").font(.system(size: 24)).foregroundStyle(Tok.claude)
                Text("Add a Claude account").font(Typo.serif(size: 18)).foregroundStyle(Tok.text)
                Text("Sign in on claude.ai — Claude Code's official login. Works with Google or email.")
                    .multilineTextAlignment(.center)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.muted)
                content
                Text("Your browser authorizes whichever claude.ai account is signed in there — switch it first with the Claude Account Switcher extension.")
                    .multilineTextAlignment(.center)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.faint)
                Text("Each account gets its own credential slot in Keychain. Your ~/.claude settings, history and plugins stay shared.")
                    .multilineTextAlignment(.center)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.faint)
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .font(Typo.ui(style))
        .onAppear { if email.isEmpty { email = model.addPrefillEmail } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.addState {
        case .idle, .failed:
            VStack(spacing: 8) {
                Button { model.addAccount(.google) } label: {
                    HStack(spacing: 8) {
                        Text("G").font(.system(size: 12, weight: .bold)).foregroundStyle(Tok.text)
                            .frame(width: 16, height: 16)
                            .background(Circle().stroke(Tok.borderStrong, lineWidth: 0.5))
                        Text("Continue with Google")
                    }
                }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary, fullWidth: true))
                HStack(spacing: 8) {
                    Hairline()
                    Text("or").font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
                    Hairline()
                }
                TextField("name@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.borderStrong, lineWidth: 0.5))
                    .onSubmit(continueWithEmail)
                Button("Continue with email", action: continueWithEmail)
                    .buttonStyle(ClaudeButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(!email.contains("@"))
                if case .failed(let message) = model.addState {
                    Text(message).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.error).multilineTextAlignment(.center)
                }
            }
        case .waiting(let method):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Spinner()
                    Text("Waiting for sign-in…")
                }
                Text(detail(for: method))
                    .multilineTextAlignment(.center)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.muted)
                Button("Cancel") { model.cancelAddAccount() }
                    .buttonStyle(ClaudeButtonStyle(kind: .ghost))
            }
        case .success(let email, let plan):
            VStack(spacing: 6) {
                Text("✓ Added \(email) · \(plan)").foregroundStyle(Tok.success)
                Text("Usage will appear in the menu bar within a minute.")
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.muted)
            }
        }
    }

    private func detail(for method: LoginMethod) -> String {
        switch method {
        case .google: return "Finish signing in with Google in your browser."
        case .email(let address): return "Continue in your browser — claude.ai emails a magic link to \(address). Open it to finish."
        }
    }

    private func continueWithEmail() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { return }
        model.addAccount(.email(address))
    }
}
```

- [ ] **Step 4: Wire the routes**

In `Sources/ClaudeUsage/RootView.swift`, replace the `switch` inside `Group`:

```swift
            switch model.route {
            case .usage: UsageView()
            case .settings: SettingsView()
            case .addAccount: AddAccountView()
            }
```

- [ ] **Step 5: Build, test and smoke-run**

Run:

```bash
swift build && swift test
swift run ClaudeUsage & APP=$!; sleep 10; kill -0 $APP && echo "still running"; kill $APP
```

Expected: build and tests pass; "still running".

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsage
git commit -m "feat(app): settings (accounts, refresh, notifications, theme) and add-account flow"
```

---

### Task 17: App bundle, notifications and QA checklist

**Files:**
- Create: `scripts/bundle.sh`, `README.md`
- Modify: `Sources/ClaudeUsage/Notifications.swift`

**Interfaces:**
- Consumes: `NotificationPosting`, `NotificationEvent` (Tasks 12, 14).
- Produces: `build/Claude Usage.app` (bundle id `com.jeff.ClaudeUsage`, `LSUIElement`, ad-hoc signed); `struct UserNotificationPoster: NotificationPosting`; `NotificationPosterFactory.make()` returns it when `Bundle.main.bundleIdentifier != nil`.

- [ ] **Step 1: Bundling script**

`scripts/bundle.sh` (make it executable with `chmod +x scripts/bundle.sh`):

```bash
#!/usr/bin/env bash
# Builds build/Claude Usage.app from the SwiftPM executable (no Xcode project).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ClaudeUsage
BIN="$(swift build -c release --show-bin-path)/ClaudeUsage"
APP="build/Claude Usage.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeUsage"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key><string>com.jeff.ClaudeUsage</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 2: Real notifications when bundled**

Replace `Sources/ClaudeUsage/Notifications.swift`:

```swift
import Foundation
import UserNotifications
import UsageCore

protocol NotificationPosting: Sendable {
    func post(_ events: [NotificationEvent])
}

struct NoopNotificationPoster: NotificationPosting {
    func post(_ events: [NotificationEvent]) {}
}

struct UserNotificationPoster: NotificationPosting {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ events: [NotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
    }
}

enum NotificationPosterFactory {
    /// UserNotifications crashes outside an app bundle (e.g. `swift run`), so fall back to a no-op there.
    static func make() -> any NotificationPosting {
        Bundle.main.bundleIdentifier == nil ? NoopNotificationPoster() : UserNotificationPoster()
    }
}
```

- [ ] **Step 3: Build the bundle and smoke-test it**

Run:

```bash
chmod +x scripts/bundle.sh && ./scripts/bundle.sh
codesign --verify --verbose "build/Claude Usage.app"
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "build/Claude Usage.app/Contents/Info.plist"
open "build/Claude Usage.app"; sleep 10; pgrep -x ClaudeUsage && echo "running"
screencapture -x -R0,0,1800,30 /tmp/cu-menubar.png
osascript -e 'tell application "Claude Usage" to quit' || pkill -x ClaudeUsage
```

Expected: "Built build/Claude Usage.app"; `codesign` prints "valid on disk"; `true`; "running"; `/tmp/cu-menubar.png` shows `✻ NN% · NN%` in the menu bar (view it with the Read tool); the app quits.

- [ ] **Step 4: README with the manual QA checklist**

`README.md`:

```markdown
# ✻ Claude Usage

A tiny macOS menu bar app that shows every Claude account's limits — 5-hour session, week, week per model
(Fable, …) — whether you are burning faster than the window allows, and what your Claude Code use on this Mac
would cost at API prices. Add accounts with Claude Code's own login (Google or email magic link) and switch the
terminal between them in one click.

Unofficial; not affiliated with Anthropic.

## Install

1. Download `ClaudeUsage.zip` from the latest release and unzip it.
2. Move `Claude Usage.app` to `/Applications`.
3. First launch: right-click → **Open** (the app is not notarized), or run
   `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"`.

Requires macOS 14+ and Claude Code installed (`claude` on your PATH).

## Build from source

    make test     # swift test
    make app      # build/Claude Usage.app
    make run      # build and open it
    make cli ARGS="--read-only status"

## How it works

- Limits come from the same endpoint Claude Code's `/usage` uses, called with each account's OAuth token.
- The terminal's account is `~/.claude.json` → `oauthAccount` plus the `Claude Code-credentials` Keychain item.
  "Use in terminal" swaps only those (MCP logins and settings are kept).
- Other accounts' tokens live in your Keychain under "Claude Usage". Nothing leaves your Mac except calls to
  Anthropic's API.
- Spend is estimated from `~/.claude/projects/**/*.jsonl` with public API prices (`pricing.json` in
  `~/Library/Application Support/ClaudeUsage/` overrides them; run `claude-usage-cli reindex` after editing).

## Manual QA checklist (before each release)

- [ ] Light and dark appearance × CLI and Claude themes: popover matches `prototypes/menubar.html`.
- [ ] Menu bar title shows `✻ session% · week%` within 10 s of launch; each "Menu bar shows" option works.
- [ ] Add account with **Continue with Google**: browser opens, after sign-in the account appears with its limits.
- [ ] Add account with **Continue with email**: magic link arrives, login completes, account appears.
- [ ] Cancel during "Waiting for sign-in…": no leftover folder in `~/Library/Application Support/ClaudeUsage/login/`
      and no `Claude Code-credentials-…` item for it (`security dump-keychain | grep -c "Claude Code-credentials"`
      is unchanged).
- [ ] **Use in terminal** on another account, then in a new terminal: `claude auth status --json` shows that
      email; `/mcp` still lists your authenticated MCP servers; switching back restores the first account.
- [ ] Remove an account: it disappears and its "Claude Usage" Keychain item is gone.
- [ ] Notifications: with an account above 80 %, one notification appears once per window.
- [ ] Launch at login toggle works from `/Applications`.
- [ ] `python3 scripts/verify_spend.py` and the popover's "today" agree within 1 %.
```

- [ ] **Step 5: Run the full suite and commit**

Run: `swift build && swift test`
Expected: all pass.

```bash
git add scripts/bundle.sh README.md Sources/ClaudeUsage/Notifications.swift
git commit -m "build: app bundle script, real notifications and manual QA checklist"
```

---

### Task 18: Distribution files and landing page

**Files:**
- Create: `scripts/release.sh`, `LICENSE`, `site/index.html`, `site/tokens.css` (copy of `prototypes/tokens.css`), `site/screenshot.png` (copy of `prototypes/shots/menubar-usage-dark-cli-stats.png`)
- Create: `docs/notes/site-390.png`, `docs/notes/site-1280.png` (verification screenshots)

**Interfaces:**
- Consumes: `scripts/bundle.sh` (Task 17), `prototypes/tokens.css`, `prototypes/shots/menubar-usage-dark-cli-stats.png`.
- Produces: `build/ClaudeUsage.zip` (exact asset name) via `scripts/release.sh`; a static `site/` folder deployable as-is. This task does **not** run `gh repo create`, `gh release create` or `vercel deploy` — the controller does that after the final review.

- [ ] **Step 1: Release script**

`scripts/release.sh` (`chmod +x scripts/release.sh`):

```bash
#!/usr/bin/env bash
# Produces build/ClaudeUsage.zip — the GitHub release asset (unversioned name keeps latest/download stable).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
rm -f build/ClaudeUsage.zip
ditto -c -k --keepParent "build/Claude Usage.app" build/ClaudeUsage.zip
shasum -a 256 build/ClaudeUsage.zip
echo "Release asset: build/ClaudeUsage.zip"
```

Run: `./scripts/release.sh && unzip -l build/ClaudeUsage.zip | head -5`
Expected: a sha256 line; the listing starts with `Claude Usage.app/`.

- [ ] **Step 2: License**

`LICENSE`:

```text
MIT License

Copyright (c) 2026 Jeff

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Landing page assets**

```bash
mkdir -p site
cp prototypes/tokens.css site/tokens.css
cp prototypes/shots/menubar-usage-dark-cli-stats.png site/screenshot.png
```

`site/index.html`:

```html
<!doctype html>
<html lang="en" data-style="app">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Usage</title>
<meta name="description" content="Every Claude account's limits, pace and spend — one click away in your macOS menu bar.">
<link rel="stylesheet" href="tokens.css">
<style>
  body { font-size: 15px; line-height: 1.6; }
  main { max-width: 960px; margin: 0 auto; padding: 56px 16px 72px; }
  .hero { display: grid; grid-template-columns: 1.1fr 0.9fr; gap: 48px; align-items: center; }
  h1 { font-family: var(--font-serif); font-weight: 400; font-size: 44px; line-height: 1.1; margin: 0 0 16px; }
  h1 .claude { font-family: var(--font-mono); }
  .lead { color: var(--text-2); font-size: 18px; margin: 0 0 28px; max-width: 34ch; }
  .actions { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
  .download { height: 42px; padding: 0 18px; font-size: 15px; border-radius: var(--r-md); text-decoration: none; }
  .meta { color: var(--muted); font-family: var(--font-mono); font-size: 12px; margin-top: 14px; }
  .shot { width: 100%; max-width: 360px; justify-self: center; border-radius: var(--r-lg); box-shadow: var(--shadow); }
  section { margin-top: 72px; }
  h2 { font-family: var(--font-mono); font-size: 13px; font-weight: 500; color: var(--muted); margin: 0 0 16px; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  .card { background: var(--surface); border: 0.5px solid var(--border); border-radius: var(--r-lg); padding: 16px; }
  .card b { display: block; margin-bottom: 4px; }
  .card span, li span { color: var(--muted); font-size: 14px; }
  ol { margin: 0; padding-left: 20px; }
  ol li { margin-bottom: 10px; }
  code { font-family: var(--font-mono); font-size: 12.5px; background: var(--surface-2); border: 0.5px solid var(--border);
         border-radius: var(--r-sm); padding: 1px 5px; word-break: break-all; }
  footer { margin-top: 72px; color: var(--faint); font-family: var(--font-mono); font-size: 12px;
           display: flex; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
  a { color: var(--claude); }
  @media (max-width: 760px) {
    main { padding-top: 32px; }
    .hero { grid-template-columns: 1fr; gap: 32px; }
    h1 { font-size: 34px; }
    .grid { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<main>
  <div class="hero">
    <div>
      <h1><span class="claude">✻</span> Claude Usage</h1>
      <p class="lead">Every Claude account's limits, pace and spend — one click away in your menu bar.</p>
      <div class="actions">
        <a class="btn primary download"
           href="https://github.com/Jeff909Dev/claude-code-usage/releases/latest/download/ClaudeUsage.zip">Download for macOS</a>
        <a class="btn ghost download" href="https://github.com/Jeff909Dev/claude-code-usage">View on GitHub</a>
      </div>
      <p class="meta">v0.1.0 · macOS 14+ · free, MIT</p>
    </div>
    <img class="shot" src="screenshot.png" alt="Claude Usage popover showing session, weekly and Fable limits, pace and spend">
  </div>

  <section>
    <h2>what it shows</h2>
    <div class="grid">
      <div class="card"><b>Limits per account</b><span>5-hour session, week, and week per model — with a pace marker and when you'd hit 100%.</span></div>
      <div class="card"><b>Which account to use</b><span>Add every account with Claude Code's own login and move the terminal to the one with headroom.</span></div>
      <div class="card"><b>Spend on this Mac</b><span>API-equivalent cost from your local transcripts: today, 7 and 30 days, models and projects.</span></div>
    </div>
  </section>

  <section>
    <h2>install</h2>
    <ol>
      <li>Download <code>ClaudeUsage.zip</code> and unzip it.</li>
      <li>Move <b>Claude Usage.app</b> to <code>/Applications</code>.</li>
      <li>First launch: right-click the app → <b>Open</b> <span>(it isn't notarized)</span>, or run
        <code>xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"</code></li>
    </ol>
  </section>

  <section>
    <h2>requirements</h2>
    <ul>
      <li>macOS 14 Sonoma or later</li>
      <li>Claude Code installed and signed in at least once (<code>claude</code> on your PATH)</li>
    </ul>
  </section>

  <footer>
    <span>Unofficial · not affiliated with Anthropic · tokens stay in your Keychain</span>
    <a href="https://github.com/Jeff909Dev/claude-code-usage">github.com/Jeff909Dev/claude-code-usage</a>
  </footer>
</main>
</body>
</html>
```

No `vercel.json` is needed: the site is a single `index.html` with relative assets.

- [ ] **Step 4: Verify the page renders at phone and desktop widths**

Using the Playwright MCP tools (load them with ToolSearch `select:mcp__plugin_playwright_playwright__browser_navigate,mcp__plugin_playwright_playwright__browser_resize,mcp__plugin_playwright_playwright__browser_take_screenshot,mcp__plugin_playwright_playwright__browser_evaluate,mcp__plugin_playwright_playwright__browser_console_messages`):
1. Navigate to `site/index.html` in this checkout (a `file://` URL).
2. Resize to 390 × 844, take a full-page screenshot to `docs/notes/site-390.png`; evaluate `document.documentElement.scrollWidth <= window.innerWidth` → must be `true` (no horizontal scroll).
3. Resize to 1280 × 900, full-page screenshot to `docs/notes/site-1280.png`.
4. Console messages: no errors (the screenshot and tokens.css load).
Look at both screenshots with the Read tool; fix spacing or overflow issues before committing.

- [ ] **Step 5: Secret scan before anything can be pushed**

Run:

```bash
git ls-files -co --exclude-standard | grep -v '^\.build/' | xargs grep -nIE 'sk-ant-[A-Za-z0-9_-]{8,}|"accessToken":"[^"a][^"]{20,}|"refreshToken":"[^"r][^"]{20,}' || echo "clean"
```

Expected: `clean` (test fixtures only use `at-<tag>` / `rt-<tag>` values). If anything matches, stop and report it.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh LICENSE site docs/notes/site-390.png docs/notes/site-1280.png
git commit -m "chore: release script, MIT license and landing page"
```

---

## Self-review notes

- Spec coverage: §1 success criteria → Tasks 13 (timings, 1 % check), 14 (title within 10 s), 10/17 (switch keeps MCP); §2 facts → Tasks 1–3, 9, 11; §4 architecture → file map above (Stats in `Stats.swift`, LimitsSection/StatsSection/AccountChips split as listed); §5 → Task 8; §6 → Tasks 9–10; §7 → Task 11 + 16; §8 → Tasks 4, 14, 15; §9 → Tasks 5–7; §10 → Tasks 12, 14, 16, 17; §11 → Tasks 14–16; §12 → every task's tests + Task 17 checklist; §13 respected; §14 risks → Task 1 notes + Task 17 checklist; §15 → Task 18 (publishing commands left to the controller).
- Interpretation recorded: spec §11's "CLI / Claude / System" is implemented as Theme (CLI | Claude) plus Appearance (System | Dark | Light).

