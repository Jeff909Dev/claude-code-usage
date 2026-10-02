import SwiftUI
import UsageCore

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        // Reset countdowns, pace and "1m ago" move with the clock, not only when new numbers arrive.
        TimelineView(.everyMinute) { context in
            VStack(spacing: 0) {
                if let account = model.displayedAccount {
                    UsageHeader(account: account, now: context.date)
                    if model.accounts.count > 1 { AccountChips() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            LimitsSection(account: account, now: context.date)
                            if let best = model.bestAccountID.flatMap(model.account(id:)) {
                                Hairline()
                                BestAccountCallout(account: best)
                            }
                            Hairline()
                            StatsSection()
                        }
                    }
                } else {
                    NoAccountYet()
                }
                Hairline()
                UsageFooter()
            }
        }
        .font(Typo.ui(style))
        .foregroundStyle(Tok.text)
    }
}

struct UsageHeader: View {
    let account: Account
    let now: Date
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 8) {
                AvatarView(account: account)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(account.label).font(Typo.ui(style, size: 12, weight: .semibold))
                        Badge(text: account.plan)
                    }
                    HStack(spacing: 0) {
                        Text(account.email).foregroundStyle(Tok.muted).truncationMode(.middle)
                        if account.id == model.terminalID {
                            HStack(spacing: 0) {
                                Text(" · ").foregroundStyle(Tok.faint)
                                TerminalTag()
                            }
                            .fixedSize()
                        }
                    }
                    .font(Typo.ui(style, size: 10))
                }
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if let ago = Format.ago(model.state(for: account.id)?.lastSuccess, now: now) {
                    Text(ago)
                        .font(Typo.ui(style, size: 10))
                        .foregroundStyle(Tok.faint)
                        .padding(.trailing, 2)
                }
                IconButton(systemName: "arrow.clockwise", help: "Refresh now", isSpinning: model.isRefreshing) {
                    Task { await model.refreshNow(force: true) }
                }
                IconButton(systemName: "slider.horizontal.3", help: "Settings") { model.route = .settings }
            }
            .fixedSize()
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
    }
}

/// Chooses which account the popover shows; it never changes the terminal's account.
struct AccountChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.accounts) { account in
                    AccountChip(account: account, selected: account.id == model.displayedAccount?.id,
                                isTerminal: account.id == model.terminalID,
                                needsSignIn: model.state(for: account.id)?.status == .needsSignIn) {
                        model.selectedID = account.id
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
    }
}

private struct AccountChip: View {
    let account: Account
    let selected: Bool
    let isTerminal: Bool
    let needsSignIn: Bool
    let action: () -> Void
    @Environment(\.themeStyle) private var style
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                AvatarView(account: account, size: 14)
                Text(account.label).lineLimit(1)
                if isTerminal { Dot(color: Tok.claude) }
                if needsSignIn { Dot(color: Tok.error) }
            }
            .font(Typo.ui(style, size: 10))
            .foregroundStyle(selected || hovering ? Tok.text : Tok.muted)
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .frame(height: 22)
            .background(Capsule().fill(selected ? Tok.surface2 : (hovering ? Tok.surface : Color.clear)))
            .overlay(Capsule().strokeBorder(selected ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(account.email)
        .onHover { hovering = $0 }
    }

    private struct Dot: View {
        let color: Color
        var body: some View { Circle().fill(color).frame(width: 5, height: 5) }
    }
}

private struct NoAccountYet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Text("✻").font(.system(size: 26, design: .monospaced)).foregroundStyle(Tok.claude)
            Text("No Claude account yet").foregroundStyle(Tok.text2)
            Button("+ Add account") { model.route = .addAccount }
                .buttonStyle(ClaudeButtonStyle(kind: .primary))
            if let problem = model.pollError {
                Notice(title: problem)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 28)
    }
}

struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(spacing: 8) {
            Text("Refreshes every \(Int(model.settings.refreshInterval / 60)) min" + (model.readOnly ? " · read-only" : ""))
                .foregroundStyle(Tok.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { model.quit() } label: {
                HStack(spacing: 5) {
                    Text("Quit")
                    KeyCap(text: "⌘Q")
                }
            }
            .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
            .keyboardShortcut("q")
        }
        .font(Typo.ui(style, size: 10))
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 8))
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Tok.muted)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 3).fill(Tok.surface2))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Tok.borderStrong, lineWidth: 0.5))
    }
}
