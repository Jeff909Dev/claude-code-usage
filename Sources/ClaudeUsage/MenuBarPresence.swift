/// Whether the menu bar item shows, and when to explain why it doesn't. Control Center hides it when the user turns it
/// off in System Settings › Menu Bar; with nothing on screen the app would look like it never opened.
struct MenuBarPresence: Equatable {
    private(set) var isVisible = true
    private(set) var showsHelp = false

    /// The status item's visibility changed, or was checked after launch.
    mutating func visibilityChanged(visible: Bool) {
        if visible {
            showsHelp = false
        } else if isVisible {
            showsHelp = true
        }
        isVisible = visible
    }

    /// "Show again", or the app was opened again while it runs.
    mutating func showAgain() {
        isVisible = true
        showsHelp = false
    }

    mutating func helpClosed() { showsHelp = false }
}
