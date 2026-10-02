import Foundation
import Testing
@testable import UsageCore

struct SettingsPresentationTests {
    func state(_ status: AccountStatus) -> AccountRefreshState {
        AccountRefreshState(snapshot: .fake(), lastSuccess: nil, status: status, consecutiveRateLimits: 0,
                            backoffUntil: nil, isStale: false)
    }

    // MARK: Email

    @Test func emailIsTrimmedWhenItLooksLikeAnAddress() {
        #expect(EmailAddress.validated("name@example.com") == "name@example.com")
        #expect(EmailAddress.validated("  someone+work@example.co.uk \n") == "someone+work@example.co.uk")
    }

    @Test(arguments: ["", "   ", "name", "name@", "@example.com", "name@example", "name@@example.com",
                      "a@b@example.com", "na me@example.com", "name@exam ple.com", "name@.example.com",
                      "name@example.com.", "name@exa..mple.com", "name@example.com\tx"])
    func emailWithoutTheShapeOfAnAddressIsRefused(_ text: String) {
        #expect(EmailAddress.validated(text) == nil)
    }

    /// It becomes the value of `claude auth login --email`; one starting with "-" would read as an option.
    @Test func emailThatLooksLikeAnOptionIsRefused() {
        #expect(EmailAddress.validated("--help@example.com") == nil)
        #expect(EmailAddress.validated(" -x@example.com") == nil)
    }

    // MARK: Account rows

    @Test func terminalAccountCanOnlyBeRenamed() {
        let row = AccountRowModel.make(accountID: "a", state: state(.ok), terminalID: "a", readOnly: false)
        #expect(row.isTerminal)
        #expect(row.statusText == "● terminal")
        #expect(row.statusTone == .terminal)
        #expect(row.actions == [.rename])
    }

    @Test func otherAccountCanBeUsedRenamedAndRemoved() {
        let row = AccountRowModel.make(accountID: "b", state: state(.ok), terminalID: "a", readOnly: false)
        #expect(!row.isTerminal)
        #expect(row.statusText == "token ok")
        #expect(row.statusTone == .muted)
        #expect(row.actions == [.useInTerminal, .rename, .remove])
    }

    @Test func signedOutAccountOffersSignInInsteadOfTheTerminal() {
        let row = AccountRowModel.make(accountID: "b", state: state(.needsSignIn), terminalID: "a", readOnly: false)
        #expect(row.statusText == "needs sign-in")
        #expect(row.statusTone == .error)
        #expect(row.actions == [.signIn, .rename, .remove])
    }

    @Test func signedOutTerminalAccountKeepsItsTagAndOffersSignIn() {
        let row = AccountRowModel.make(accountID: "a", state: state(.needsSignIn), terminalID: "a", readOnly: false)
        #expect(row.statusText == "● terminal")
        #expect(row.actions == [.signIn, .rename])
    }

    @Test func statusWordsComeFromStatusText() {
        let offline = AccountRowModel.make(accountID: "b", state: state(.offline), terminalID: "a", readOnly: false)
        #expect(offline.statusText == "offline")
        #expect(offline.actions == [.useInTerminal, .rename, .remove])
        let unknown = AccountRowModel.make(accountID: "b", state: nil, terminalID: nil, readOnly: false)
        #expect(unknown.statusText == "no data")
        #expect(unknown.statusTone == .muted)
        #expect(!unknown.isTerminal)
    }

    /// Read-only mode changes no account: no switching, signing in or removing, and no renaming either (it would
    /// only change the throw-away scratch copy of the account list).
    @Test func readOnlyOffersNoActions() {
        for status in [AccountStatus.ok, .needsSignIn, .offline] {
            #expect(AccountRowModel.make(accountID: "b", state: state(status), terminalID: "a", readOnly: true)
                .actions.isEmpty)
        }
        #expect(AccountRowModel.make(accountID: "a", state: state(.needsSignIn), terminalID: "a", readOnly: true)
            .actions.isEmpty)
    }

    /// VoiceOver reads the row as one sentence; the terminal tag is spoken as words, with the token status after it.
    @Test func accessibilityLabelNamesTheAccountAndItsStatus() {
        let other = AccountRowModel.make(accountID: "b", state: state(.needsSignIn), terminalID: "a", readOnly: false)
        #expect(other.accessibilityLabel(label: "Lab", email: "lab@example.com")
            == "Lab, lab@example.com, needs sign-in")
        let terminal = AccountRowModel.make(accountID: "a", state: state(.ok), terminalID: "a", readOnly: false)
        #expect(terminal.accessibilityLabel(label: "Work", email: "work@example.com")
            == "Work, work@example.com, in the terminal, token ok")
        let unknown = AccountRowModel.make(accountID: "c", state: nil, terminalID: "a", readOnly: false)
        #expect(unknown.accessibilityLabel(label: "Studio", email: "studio@example.com")
            == "Studio, studio@example.com, no data")
    }

    @Test func switchingAndRemovingAreTheActionsThatChangeAccounts() {
        #expect(AccountRowModel.Action.useInTerminal.changesAccounts)
        #expect(AccountRowModel.Action.remove.changesAccounts)
        #expect(!AccountRowModel.Action.signIn.changesAccounts)
        #expect(!AccountRowModel.Action.rename.changesAccounts)
    }

    @Test func signedInNoteCountsAccountsThatDoNotNeedSignIn() {
        let states = ["a": state(.ok), "b": state(.needsSignIn), "c": state(.offline)]
        #expect(AccountRowModel.signedInNote(accountIDs: ["a", "b", "c", "d"], states: states) == "3 signed in")
        #expect(AccountRowModel.signedInNote(accountIDs: ["b"], states: states) == "0 signed in")
        #expect(AccountRowModel.signedInNote(accountIDs: [], states: states) == nil)
    }

    // MARK: Claude Code path

    @Test func claudePathAbbreviatesTheHomeFolder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ClaudePathText.display(URL(fileURLWithPath: "/Users/someone/.local/bin/claude"), isLocating: false,
                                       home: home) == "~/.local/bin/claude")
        #expect(ClaudePathText.display(URL(fileURLWithPath: "/opt/homebrew/bin/claude"), isLocating: false,
                                       home: home) == "/opt/homebrew/bin/claude")
        #expect(ClaudePathText.display(URL(fileURLWithPath: "/Users/someoneelse/bin/claude"), isLocating: false,
                                       home: home) == "/Users/someoneelse/bin/claude")
    }

    @Test func claudePathSaysWhenItIsBeingLookedUpOrMissing() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ClaudePathText.display(nil, isLocating: true, home: home) == "looking…")
        #expect(ClaudePathText.display(URL(fileURLWithPath: "/opt/homebrew/bin/claude"), isLocating: true,
                                       home: home) == "looking…")
        #expect(ClaudePathText.display(nil, isLocating: false, home: home) == "not found")
    }
}
