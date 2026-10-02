import AppKit
import SwiftUI
import UsageCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.route {
            case .usage: UsageView()
            case .settings: SettingsView()
            case .addAccount: AddAccountView()
            }
        }
        .frame(width: Popover.width, height: Popover.height, alignment: .top)
        .background(Tok.bg)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tok.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface3))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.borderStrong, lineWidth: 0.5))
                    // Above the footer, which keeps Quit reachable.
                    .padding(.horizontal, 12)
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        // The popover's window may keep this view alive between openings, so onAppear can fire only once; the window
        // becomes key on every opening. Both calls are cheap: popoverOpened() skips data younger than 60 s.
        .onAppear { model.popoverOpened() }
        .background(WindowBecameKey { model.popoverOpened() })
    }
}

/// The popover's size. MenuBarExtra sizes its window from the content's minimum size, and a ScrollView's minimum height
/// is zero: without a definite height the popover opens as just its header and footer.
enum Popover {
    static let width: CGFloat = 340
    /// Read once, from the screen the app starts on.
    static let height = height(visibleScreenHeight: NSScreen.main?.visibleFrame.height)

    /// 600 pt, or less on a screen too short for it (the menu bar and the Dock left out), with a margin below.
    static func height(visibleScreenHeight: CGFloat?) -> CGFloat {
        min(600, (visibleScreenHeight ?? .infinity) - 40)
    }
}

/// Calls `action` each time the window hosting this view becomes key.
private struct WindowBecameKey: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(action: action) }

    func updateNSView(_ view: Watcher, context: Context) { view.action = action }

    final class Watcher: NSView {
        var action: @MainActor () -> Void
        private var observer: (any NSObjectProtocol)?

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        /// Never takes a click from the content above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Follows the view into (and out of) its window, so only this window's openings count.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                       queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.action() }
                }
            }
        }
    }
}
