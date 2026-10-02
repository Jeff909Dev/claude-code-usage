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

    /// Missing or unreadable keys fall back to defaults, so older (or newer) settings files keep working.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = AppSettings()
        refreshMinutes = value(.refreshMinutes, or: d.refreshMinutes)
        menuBarMode = value(.menuBarMode, or: d.menuBarMode)
        notifyAt80 = value(.notifyAt80, or: d.notifyAt80)
        notifyAt95 = value(.notifyAt95, or: d.notifyAt95)
        notifyOnReset = value(.notifyOnReset, or: d.notifyOnReset)
        launchAtLogin = value(.launchAtLogin, or: d.launchAtLogin)
        style = value(.style, or: d.style)
        appearance = value(.appearance, or: d.appearance)
        claudePath = try? c.decodeIfPresent(String.self, forKey: .claudePath)
    }

    public static func load(from url: URL) -> AppSettings {
        JSONFile.load(AppSettings.self, from: url) ?? AppSettings()
    }

    public func save(to url: URL) throws {
        try JSONFile.save(self, to: url)
    }

    public var thresholds: [Int] { (notifyAt80 ? [80] : []) + (notifyAt95 ? [95] : []) }

    /// Seconds between poll rounds; a hand-edited file can't make the app poll more than once a minute.
    public var refreshInterval: TimeInterval { TimeInterval(min(max(refreshMinutes, 1), 60) * 60) }
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
    /// nil: the account has no state yet.
    public static func of(_ status: AccountStatus?) -> String {
        switch status {
        case .ok: return "token ok"
        case .needsSignIn: return "needs sign-in"
        case .offline: return "offline"
        case .rateLimited: return "rate-limited"
        case .waitingForClaudeCode: return "waiting for Claude Code"
        case nil: return "no data"
        }
    }

    /// Like `of(_:)`, and an ok state that never fetched anything (skipped while ~/.claude.json was unreadable) has
    /// no data either.
    public static func of(state: AccountRefreshState?) -> String {
        guard let state, state.snapshot != nil || state.status != .ok else { return "no data" }
        return of(state.status)
    }

    /// A one-line explanation for a toast or the add-account screen. Errors never carry secrets.
    public static func message(for error: any Error) -> String {
        switch error {
        case SwitchError.unknownAccount: return "That account is no longer listed"
        case SwitchError.missingCredentials: return "No saved login for that account — sign in again"
        case SwitchError.alreadyActive: return "The terminal already uses that account"
        case SwitchError.needsSignIn: return "Sign in to that account again first"
        case SwitchError.inconsistentTerminal: return "Claude Code's login belongs to another listed account"
        case SwitchError.unknownTerminalOwner: return "Claude Code holds a login that ~/.claude.json doesn't name"
        case SwitchError.terminalChanging: return "Claude Code kept changing its login — try again"
        case SwitchError.rollbackFailed:
            return "The switch failed and Claude Code's previous login couldn't be restored — the terminal may be in "
                + "a mixed state; run `claude auth login`"
        case RemoveAccountError.inTerminal: return "Switch the terminal to another account first"
        case TerminalAccountError.notAnObject: return "~/.claude.json isn't a JSON object"
        case TerminalAccountError.lockTimeout: return "~/.claude.json is being written by Claude Code — try again"
        case TerminalAccountError.lockFailed(let code): return "Couldn't lock ~/.claude.json: \(posix(code))"
        case TerminalAccountError.concurrentModification:
            return "~/.claude.json kept changing while it was being updated — try again"
        case TerminalAccountError.renameFailed(let code): return "Couldn't write ~/.claude.json: \(posix(code))"
        case TerminalAccountError.invalidReplacement:
            return "The account's saved details are incomplete — sign in to it again"
        case SecretStoreError.commandFailed(let operation, let status):
            return "Keychain \(operation) failed (status \(status))"
        case SecretStoreError.verificationFailed: return "The Keychain didn't keep what was written"
        case SecretStoreError.invalidName: return "Invalid Keychain item name"
        case CredentialsJSONError.notAnObject: return "Claude Code's Keychain item isn't a JSON object"
        case CredentialsJSONError.invalidOAuthValue: return "Claude Code's Keychain item holds an unreadable login"
        case UsageAPIError.unauthorized: return "Anthropic rejected the account's login"
        case UsageAPIError.rateLimited: return "Rate-limited by Anthropic — try again in a few minutes"
        case UsageAPIError.http(let status): return "Anthropic's server answered HTTP \(status)"
        case UsageAPIError.decoding: return "Anthropic's server sent an answer this version can't read"
        case UsageAPIError.network(let code):
            return Int(code).map { URLError(URLError.Code(rawValue: $0)).localizedDescription } ?? "Network error"
        case LoginError.failed(let code): return "Sign-in failed (claude exited with \(code))"
        case LoginError.timedOut: return "Sign-in timed out after 10 minutes"
        case LoginError.cancelled: return "Sign-in cancelled"
        case LoginError.noCredentials: return "Claude Code didn't save a login — try again"
        case LoginError.couldNotLaunch: return "Couldn't start Claude Code — check its path in Settings"
        default:
            // Foundation's errors (files, JSON, network) read best localized; ours describe themselves.
            let ns = error as NSError
            return ns.domain.hasPrefix("NS") ? ns.localizedDescription : String(describing: error)
        }
    }

    static func posix(_ code: Int32) -> String { String(cString: strerror(code)) }

    /// Why "Use in terminal" failed. The switcher puts Claude Code's item back before it rethrows, so the terminal is
    /// unchanged unless that restore failed, or a Keychain write's read-back failed (the write may have landed).
    public static func switchFailure(_ error: any Error) -> String {
        switch error {
        case SwitchError.rollbackFailed: return message(for: error)
        case SecretStoreError.verificationFailed:
            return "Couldn't switch: \(message(for: error)) — check `claude auth status`"
        default: return "Couldn't switch — terminal unchanged: \(message(for: error))"
        }
    }

    /// Why "Add account" failed. Sign-in errors already say so.
    public static func signInFailure(_ error: any Error) -> String {
        error is LoginError ? message(for: error) : "Sign-in failed: \(message(for: error))"
    }
}
