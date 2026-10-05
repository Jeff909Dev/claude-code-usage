import AppKit
import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // The menu bar item and its popover are AppKit (StatusItemController). SwiftUI needs a scene; this one opens no
    // window by itself.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --read-only never refreshes a token or writes a login, and keeps the app's own files in a scratch folder.
        let readOnly = CommandLine.arguments.contains("--read-only")
        let env: CoreEnvironment
        do { env = try CoreEnvironment.live(readOnly: readOnly) } catch {
            fatalError("Cannot create the Application Support folder: \(error)")
        }
        let model = AppModel(env: env, readOnly: readOnly, poster: NotificationPosterFactory.make(readOnly: readOnly))
        self.model = model
        model.start()
        statusItem = StatusItemController(model: model)
    }

    /// Opening the app while it runs (Finder, Spotlight, `open`) shows the menu bar item and its popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.reopen()
        return true
    }
}
