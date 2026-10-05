import AppKit
import Observation
import SwiftUI

/// The menu bar item: the model's title, and a click opens RootView in a popover. It is AppKit rather than SwiftUI's
/// MenuBarExtra, which names its item "Item-0" like every other app's and quits the app when Control Center hides it.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var presence = MenuBarPresence()
    private var visibility: NSKeyValueObservation?
    private lazy var helpWindow = MenuBarHiddenWindow(
        showAgain: { [weak self] in self?.showAgain() },
        closed: { [weak self] in self?.change { $0.helpClosed() } })

    init(model: AppModel) {
        self.model = model
        super.init()
        // Control Center keeps the item's visibility under this name.
        statusItem.autosaveName = "com.jeff909dev.ClaudeUsage.status"
        // Command-drag can't remove it, and being hidden never quits the app.
        statusItem.behavior = []
        // AppKit names a new item "Item-0" and restores the visibility saved under that name, which MenuBarExtra used.
        // Ask for it on every launch: if the user turned it off in System Settings, Control Center keeps it hidden and
        // the help window says so.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        // A definite size: RootView's ScrollView has no minimum height of its own.
        popover.contentSize = NSSize(width: Popover.width, height: Popover.height)
        popover.contentViewController = NSHostingController(rootView: PopoverContent(model: model))
        showTitle()
        visibility = statusItem.observe(\.isVisible) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let visible = self.statusItem.isVisible
                self.change { $0.visibilityChanged(visible: visible) }
            }
        }
        checkSoon()
    }

    /// The app was opened again while it runs: show the item, and its popover if the item is in the menu bar.
    func reopen() {
        showAgain()
        if isShowing { showPopover() }
    }

    /// Whether the item is in the menu bar. Control Center can keep an item the app asks to show out of it (System
    /// Settings › Menu Bar) without telling the app; the item's window is then never on screen.
    private var isShowing: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Looks a moment later, once Control Center has placed the item or not. Only then: the menu bar also hides every
    /// item while an app is full screen.
    private func checkSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let showing = isShowing
            change { $0.visibilityChanged(visible: showing) }
        }
    }

    private func showAgain() {
        statusItem.isVisible = true
        change { $0.showAgain() }
        checkSoon()
    }

    /// Sets the title, then again each time the model changes it.
    private func showTitle() {
        withObservationTracking {
            statusItem.button?.title = model.menuBarTitle
        } onChange: { [weak self] in
            Task { @MainActor in self?.showTitle() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // The app has no Dock icon and isn't active; the popover's text fields need it to be.
        NSApplication.shared.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.popoverOpened()
    }

    private func change(_ update: (inout MenuBarPresence) -> Void) {
        var next = presence
        update(&next)
        guard next != presence else { return }
        presence = next
        if presence.showsHelp { helpWindow.show() } else { helpWindow.close() }
    }
}

/// What RootView needs from its surroundings, following the settings as they change.
private struct PopoverContent: View {
    let model: AppModel

    var body: some View {
        RootView()
            .environment(model)
            .environment(\.themeStyle, model.settings.style)
            .preferredColorScheme(model.settings.appearance.colorScheme)
    }
}
