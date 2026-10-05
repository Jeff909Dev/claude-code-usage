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
    }
}

/// The popover's size. A ScrollView's minimum height is zero: without a definite height the popover opens as just its
/// header and footer.
enum Popover {
    static let width: CGFloat = 340
    /// Read once, from the screen the app starts on.
    static let height = height(visibleScreenHeight: NSScreen.main?.visibleFrame.height)

    /// 600 pt, or less on a screen too short for it (the menu bar and the Dock left out), with a margin below.
    static func height(visibleScreenHeight: CGFloat?) -> CGFloat {
        min(600, (visibleScreenHeight ?? .infinity) - 40)
    }
}
