import AppKit
import SwiftUI

/// The app's only regular window: it says why the menu bar item is gone and how to bring it back.
@MainActor
final class MenuBarHiddenWindow: NSObject, NSWindowDelegate {
    private let showAgain: () -> Void
    private let closed: () -> Void
    private var window: NSWindow?

    init(showAgain: @escaping () -> Void, closed: @escaping () -> Void) {
        self.showAgain = showAgain
        self.closed = closed
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // The app has no Dock icon and nothing else on screen; bring it forward so the window isn't left behind.
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        // Keyboard focus would otherwise start on Quit; Return still opens Menu Bar settings.
        window.makeFirstResponder(nil)
        // macOS may refuse to activate an app the user didn't just open (at login, say); show the window anyway.
        window.orderFrontRegardless()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { closed() }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 190), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Claude Usage is hidden from the menu bar"
        // The title bar takes the window's colour, so it blends with the content.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Tok.bg)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuBarHiddenView(showAgain: showAgain))
        window.delegate = self
        window.center()
        return window
    }
}

private struct MenuBarHiddenView: View {
    static let menuBarSettings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    let showAgain: () -> Void
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("✻").font(.system(size: 26, design: .monospaced)).foregroundStyle(Tok.claude)
                Text("macOS is hiding Claude Usage's menu bar item. Turn it on in System Settings › Menu Bar (Allow in "
                    + "the Menu Bar) — or Control Center on older macOS — then click Show again.")
                    .foregroundStyle(Tok.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(ClaudeButtonStyle(kind: .ghost))
                Spacer(minLength: 0)
                Button("Show again", action: showAgain)
                    .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                Button("Open Menu Bar Settings") { NSWorkspace.shared.open(Self.menuBarSettings) }
                    .buttonStyle(ClaudeButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(Typo.ui(style, size: 12))
        .foregroundStyle(Tok.text)
        .padding(20)
        .frame(width: 420, height: 190)
        .background(Tok.bg)
    }
}
