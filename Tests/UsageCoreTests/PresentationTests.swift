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
        #expect(MenuBarTitle.text(mode: .both, snapshot: s, status: .waitingForClaudeCode) == "✻ 25% · 64%")
    }

    @Test func titleShowsBangWhenTerminalNeedsSignIn() {
        #expect(MenuBarTitle.text(mode: .both, snapshot: .fake(), status: .needsSignIn) == "✻ !")
        #expect(MenuBarTitle.text(mode: .icon, snapshot: nil, status: .needsSignIn) == "✻ !")
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

    @Test func settingsKeepGoodValuesNextToABadOne() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menuBarMode":"rainbow","style":"claude"}"#.utf8))
        #expect(decoded.menuBarMode == .both)
        #expect(decoded.style == .claude)
    }

    @Test func refreshIntervalStaysWithinOneMinuteAndOneHour() {
        var s = AppSettings()
        #expect(s.refreshInterval == 300)
        s.refreshMinutes = 0
        #expect(s.refreshInterval == 60)
        s.refreshMinutes = 10_000
        #expect(s.refreshInterval == 3_600)
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
        #expect(StatusText.of(.offline) == "offline")
        #expect(StatusText.of(.rateLimited) == "rate-limited")
        #expect(StatusText.of(.waitingForClaudeCode) == "waiting for Claude Code")
    }

    /// A missing state, or an ok one that never fetched anything (a skipped account), is "no data", never "token ok".
    @Test func statusOfAStateWithoutDataSaysNoData() {
        #expect(StatusText.of(nil) == "no data")
        #expect(StatusText.of(state: nil) == "no data")
        #expect(StatusText.of(state: .initial) == "no data")
        var signedOut = AccountRefreshState.initial
        signedOut.status = .needsSignIn
        #expect(StatusText.of(state: signedOut) == "needs sign-in")
        var fetched = AccountRefreshState.initial
        fetched.snapshot = .fake()
        #expect(StatusText.of(state: fetched) == "token ok")
    }

    @Test func errorMessages() {
        #expect(StatusText.message(for: SwitchError.rollbackFailed(underlying: "commandFailed")).contains("mixed state"))
        #expect(StatusText.message(for: SwitchError.terminalChanging).contains("try again"))
        #expect(StatusText.message(for: SwitchError.needsSignIn) == "Sign in to that account again first")
        #expect(StatusText.message(for: LoginError.couldNotLaunch).contains("Settings"))
        #expect(StatusText.message(for: LoginError.failed(exitCode: 3)) == "Sign-in failed (claude exited with 3)")
        #expect(StatusText.message(for: CocoaError(.fileReadCorruptFile))
                == (CocoaError(.fileReadCorruptFile) as NSError).localizedDescription)
        #expect(StatusText.message(for: TerminalAccountError.concurrentModification)
                == "~/.claude.json kept changing while it was being updated — try again")
        #expect(StatusText.message(for: TerminalAccountError.lockFailed(13)) == "Couldn't lock ~/.claude.json: Permission denied")
        #expect(StatusText.message(for: SecretStoreError.commandFailed(operation: "write", status: 36))
                == "Keychain write failed (status 36)")
        #expect(StatusText.message(for: UsageAPIError.network(String(URLError.notConnectedToInternet.rawValue)))
                == URLError(.notConnectedToInternet).localizedDescription)
    }

    /// Every error a switch, a sign-in or a poll can surface reads as a sentence, never as a Swift enum case.
    @Test func noMessageShowsARawErrorCase() {
        let errors: [any Error] = [
            TerminalAccountError.notAnObject, TerminalAccountError.lockTimeout, TerminalAccountError.lockFailed(13),
            TerminalAccountError.concurrentModification, TerminalAccountError.renameFailed(28),
            TerminalAccountError.invalidReplacement,
            SecretStoreError.commandFailed(operation: "write", status: 36),
            SecretStoreError.verificationFailed(operation: "write"), SecretStoreError.invalidName,
            CredentialsJSONError.notAnObject, CredentialsJSONError.invalidOAuthValue,
            UsageAPIError.unauthorized, UsageAPIError.rateLimited(retryAfter: 60), UsageAPIError.http(500),
            UsageAPIError.decoding("keyNotFound"), UsageAPIError.network("-1009"), UsageAPIError.network("?"),
            SwitchError.unknownAccount, SwitchError.missingCredentials, SwitchError.alreadyActive,
            SwitchError.needsSignIn, SwitchError.inconsistentTerminal, SwitchError.unknownTerminalOwner,
            SwitchError.terminalChanging, SwitchError.rollbackFailed(underlying: "commandFailed(operation: \"write\")"),
            LoginError.failed(exitCode: 1), LoginError.timedOut, LoginError.cancelled, LoginError.noCredentials,
            LoginError.couldNotLaunch, RemoveAccountError.inTerminal,
        ]
        let caseNames = ["notAnObject", "lockTimeout", "lockFailed", "concurrentModification", "renameFailed",
                         "invalidReplacement", "commandFailed", "verificationFailed", "invalidName", "invalidOAuthValue",
                         "unauthorized", "rateLimited", "keyNotFound", "unknownAccount", "missingCredentials",
                         "alreadyActive", "needsSignIn", "inconsistentTerminal", "unknownTerminalOwner",
                         "terminalChanging", "rollbackFailed", "timedOut", "noCredentials", "couldNotLaunch",
                         "inTerminal", "operation:", "status:"]
        for error in errors {
            // "cancelled" may appear in a sentence; "lockFailed(13)" or "concurrentModification" may not.
            let raw = String(describing: error)
            let rawLooksLikeCode = raw.contains("(") || raw.contains(where: \.isUppercase)
            for text in [StatusText.message(for: error), StatusText.switchFailure(error), StatusText.signInFailure(error)] {
                #expect(!(rawLooksLikeCode && text.contains(raw)), "\(error) → \(text)")
                #expect(!caseNames.contains { text.contains($0) }, "\(error) → \(text)")
            }
        }
    }

    /// The switcher puts Claude Code's item back before it rethrows; only a failed restore, or a Keychain write whose
    /// read-back failed, can leave the terminal changed.
    @Test func switchAndSignInFailuresSayWhatHappened() {
        #expect(StatusText.switchFailure(TerminalAccountError.lockTimeout)
                == "Couldn't switch — terminal unchanged: ~/.claude.json is being written by Claude Code — try again")
        #expect(StatusText.switchFailure(SwitchError.inconsistentTerminal)
                == "Couldn't switch — terminal unchanged: Claude Code's login belongs to another listed account")
        let rollback = StatusText.switchFailure(SwitchError.rollbackFailed(underlying: "x"))
        #expect(!rollback.contains("unchanged") && rollback.contains("mixed state"))
        let unverified = StatusText.switchFailure(SecretStoreError.verificationFailed(operation: "write"))
        #expect(!unverified.contains("unchanged") && unverified.hasPrefix("Couldn't switch"))
        #expect(StatusText.signInFailure(SecretStoreError.commandFailed(operation: "read", status: 36))
                == "Sign-in failed: Keychain read failed (status 36)")
        #expect(StatusText.signInFailure(UsageAPIError.http(500)) == "Sign-in failed: Anthropic's server answered HTTP 500")
        #expect(StatusText.signInFailure(LoginError.timedOut) == "Sign-in timed out after 10 minutes")
    }
}
