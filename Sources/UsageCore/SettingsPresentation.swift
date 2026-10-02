import Foundation

/// The address typed on the add-account screen (spec §7).
public enum EmailAddress {
    /// The address without surrounding whitespace when it has the shape of one ("name@example.com"); nil otherwise.
    /// It becomes the value of `claude auth login --email`, so one starting with "-" (it would read as an option) is
    /// refused.
    public static func validated(_ text: String) -> String? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard parts.count == 2, !parts[0].isEmpty, !address.hasPrefix("-"), address.count <= 254,
              address.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return address
    }
}

/// One row of Settings' account list: what it says on the right, and the actions its hover shows.
public struct AccountRowModel: Sendable, Equatable {
    public enum Action: Sendable, Hashable {
        case useInTerminal, signIn, rename, remove

        /// Switching and removing never run together: the UI disables both while either is under way.
        public var changesAccounts: Bool { self == .useInTerminal || self == .remove }
    }

    public enum Tone: Sendable, Equatable { case terminal, error, muted }

    public var isTerminal: Bool
    /// "● terminal", "needs sign-in", or the account's status ("token ok", "offline", "no data"…).
    public var statusText: String
    public var statusTone: Tone
    /// The status as VoiceOver reads it: "in the terminal, token ok" rather than "● terminal".
    public var spokenStatus: String
    /// In display order. The terminal's account is neither switched to nor removed; read-only mode changes no
    /// account, so it offers none (a rename would only change its throw-away copy of the list).
    public var actions: [Action]

    public static func make(accountID: String, state: AccountRefreshState?, terminalID: String?,
                            readOnly: Bool) -> AccountRowModel {
        let isTerminal = accountID == terminalID
        let needsSignIn = state?.status == .needsSignIn
        var actions: [Action] = []
        if !readOnly {
            if needsSignIn { actions.append(.signIn) } else if !isTerminal { actions.append(.useInTerminal) }
            actions.append(.rename)
            if !isTerminal { actions.append(.remove) }
        }
        let status = StatusText.of(state: state)
        return AccountRowModel(
            isTerminal: isTerminal,
            statusText: isTerminal ? "● terminal" : status,
            statusTone: isTerminal ? .terminal : needsSignIn ? .error : .muted,
            spokenStatus: isTerminal ? "in the terminal, \(status)" : status,
            actions: actions)
    }

    /// "Lab, lab@example.com, needs sign-in": the whole row for VoiceOver.
    public func accessibilityLabel(label: String, email: String) -> String {
        "\(label), \(email), \(spokenStatus)"
    }

    /// "3 signed in" next to the "accounts" label; nil without accounts.
    public static func signedInNote(accountIDs: [String], states: [String: AccountRefreshState]) -> String? {
        guard !accountIDs.isEmpty else { return nil }
        return "\(accountIDs.filter { states[$0]?.status != .needsSignIn }.count) signed in"
    }
}

/// Where Settings says the claude binary is.
public enum ClaudePathText {
    /// "~/.local/bin/claude"; "looking…" while a lookup runs; "not found" when there is none.
    public static func display(_ location: URL?, isLocating: Bool, home: URL) -> String {
        if isLocating { return "looking…" }
        guard let path = location?.path else { return "not found" }
        let homePath = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }
}
