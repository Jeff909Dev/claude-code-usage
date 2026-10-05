import Testing
@testable import ClaudeUsage

/// Control Center hides the menu bar item when the user turns it off in System Settings › Menu Bar.
struct MenuBarPresenceTests {
    @Test func launchesVisibleWithoutTheHelpWindow() {
        let presence = MenuBarPresence()
        #expect(presence.isVisible)
        #expect(!presence.showsHelp)
    }

    @Test func hidingTheItemOpensTheHelpWindow() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        #expect(!presence.isVisible)
        #expect(presence.showsHelp)
    }

    @Test func showAgainShowsTheItemAndClosesTheHelpWindow() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        presence.showAgain()
        #expect(presence.isVisible)
        #expect(!presence.showsHelp)
    }

    @Test func hidingItAgainAfterShowAgainOpensTheHelpWindowAgain() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        presence.showAgain()
        presence.visibilityChanged(visible: false)
        #expect(!presence.isVisible)
        #expect(presence.showsHelp)
    }

    @Test func aVisibleItemNeedsNoHelpWindow() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: true)
        #expect(presence.isVisible)
        #expect(!presence.showsHelp)
    }

    @Test func closingTheHelpWindowLeavesTheItemHidden() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        presence.helpClosed()
        #expect(!presence.isVisible)
        #expect(!presence.showsHelp)
    }

    @Test func aRepeatedHideDoesNotReopenAClosedHelpWindow() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        presence.helpClosed()
        presence.visibilityChanged(visible: false)
        #expect(!presence.showsHelp)
    }

    @Test func openingTheAppAgainAfterClosingTheHelpWindowShowsTheItem() {
        var presence = MenuBarPresence()
        presence.visibilityChanged(visible: false)
        presence.helpClosed()
        presence.showAgain()
        #expect(presence.isVisible)
        #expect(!presence.showsHelp)
    }
}
