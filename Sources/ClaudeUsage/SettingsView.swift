import AppKit
import SwiftUI
import UsageCore

struct SettingsView: View {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"

    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: "Settings") { model.route = .usage }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AccountsSettings()
                    Hairline()
                    GeneralSettings()
                }
            }
            Hairline()
            Text("Tokens stay in your macOS Keychain · v\(Self.version)")
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 8))
        }
        .font(Typo.ui(style))
        .foregroundStyle(Tok.text)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style
    /// Read from macOS whenever Settings opens, so a change made in System Settings shows here.
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "general").padding(.bottom, 8)
            SettingRow("Refresh every") {
                Segmented(options: [(1, "1m"), (5, "5m"), (15, "15m")], selection: $model.settings.refreshMinutes)
            }
            Hairline()
            SettingRow("Menu bar shows") {
                Segmented(options: [(MenuBarMode.session, "Session"), (.week, "Week"), (.both, "Both"), (.icon, "Icon")],
                          selection: $model.settings.menuBarMode)
            }
            Hairline()
            SettingRow("Notify at 80%") { ClaudeToggle("Notify at 80%", isOn: $model.settings.notifyAt80) }
            Hairline()
            SettingRow("Notify at 95%") { ClaudeToggle("Notify at 95%", isOn: $model.settings.notifyAt95) }
            Hairline()
            SettingRow("Notify when limits reset") {
                ClaudeToggle("Notify when limits reset", isOn: $model.settings.notifyOnReset)
            }
            Hairline()
            SettingRow("Launch at login") {
                ClaudeToggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            }
            Hairline()
            SettingRow("Theme") {
                Segmented(options: [(ThemeStyle.cli, "CLI"), (.claude, "Claude")], selection: $model.settings.style)
            }
            Hairline()
            SettingRow("Appearance") {
                Segmented(options: [(Appearance.system, "System"), (.dark, "Dark"), (.light, "Light")],
                          selection: $model.settings.appearance)
            }
            Hairline()
            // The path found at launch (or after choosing one); never looked up while drawing.
            SettingRow("Claude Code",
                       detail: ClaudePathText.display(model.claudeLocation, isLocating: model.isLocatingClaude,
                                                      home: model.env.paths.home),
                       detailIsProblem: model.claudeLocation == nil && !model.isLocatingClaude) {
                HStack(spacing: 2) {
                    if model.settings.claudePath != nil {
                        Button("Auto") { model.settings.claudePath = nil }
                            .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
                            .help("Find claude on its own again")
                    }
                    Button("Choose…", action: pickClaudeBinary)
                        .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            if enabled && LaunchAtLogin.needsApproval {
                model.showToast("Allow Claude Usage in System Settings › General › Login Items")
                LaunchAtLogin.openLoginItemsSettings()
            }
        } catch {
            model.showToast(enabled ? "Launch at login needs the app in /Applications"
                                    : "Couldn't turn off launch at login: \(StatusText.message(for: error))")
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func pickClaudeBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        // Keep a symlink such as ~/.local/bin/claude: it outlives the versioned binary it points to.
        panel.resolvesAliases = false
        panel.message = "Choose the claude executable"
        panel.directoryURL = model.claudeLocation?.deletingLastPathComponent()
        // The popover's app has no window of its own; bring the panel to the front.
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return model.showToast("\(url.lastPathComponent) isn't an executable")
        }
        model.settings.claudePath = url.path
    }
}

/// A title (with an optional small line under it) and its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var detailIsProblem = false
    let control: Control
    @Environment(\.themeStyle) private var style

    init(_ title: String, detail: String? = nil, detailIsProblem: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.detailIsProblem = detailIsProblem
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Tok.text2)
                if let detail {
                    Text(detail)
                        .font(Typo.ui(style, size: 10))
                        .foregroundStyle(detailIsProblem ? Tok.error : Tok.faint)
                        .truncationMode(.middle)
                        .help(detail)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            control.fixedSize()
        }
        .frame(minHeight: 28)
        .padding(.vertical, detail == nil ? 0 : 3)
    }
}

/// The prototype's 26 × 15 switch: claude orange when on.
struct ClaudeToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(ClaudeSwitchStyle())
    }
}

private struct ClaudeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Tok.claudeStrong : Tok.surface3)
                .frame(width: 26, height: 15)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 11, height: 11).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "accounts",
                         trailing: AccountRowModel.signedInNote(accountIDs: model.accounts.map(\.id), states: model.states))
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(model.accounts) { AccountSettingsRow(account: $0) }
            }
            .padding(.horizontal, -6)
            if model.readOnly {
                Text(AppModel.readOnlyNote)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } else {
                Button("+ Add account") {
                    model.addPrefillEmail = ""
                    model.route = .addAccount
                }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary, fullWidth: true))
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Avatar, label, plan, email and status; hovering, or keyboard focus in the row, swaps the plan and status for the
/// row's actions. VoiceOver gets the same actions on the row itself.
private struct AccountSettingsRow: View {
    private enum Focus: Hashable {
        case row, name, confirmRemove, cancelRemove
        case action(AccountRowModel.Action)
    }

    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style
    @State private var hovering = false
    @State private var renaming = false
    @State private var confirmingRemove = false
    @State private var draft = ""
    @FocusState private var focus: Focus?

    var body: some View {
        let row = AccountRowModel.make(accountID: account.id, state: model.state(for: account.id),
                                       terminalID: model.terminalID, readOnly: model.readOnly)
        let showsActions = !row.actions.isEmpty && (confirmingRemove || (!renaming && (hovering || focus != nil)))
        HStack(spacing: 8) {
            AvatarView(account: account)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if renaming {
                        nameField
                    } else {
                        Text(account.label).fontWeight(.semibold)
                    }
                    if !showsActions && !renaming { Badge(text: account.plan).fixedSize() }
                }
                Text(account.email)
                    .font(Typo.ui(style, size: 10))
                    .foregroundStyle(Tok.muted)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if confirmingRemove {
                    removeConfirmation
                } else if showsActions {
                    actions(row.actions)
                } else {
                    status(row)
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 6).fill(showsActions ? Tok.surface : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // In the key view loop only with keyboard navigation on (as buttons are), and never takes focus on a click.
        .focusable(!row.actions.isEmpty, interactions: .activate)
        .focused($focus, equals: .row)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel(label: account.label, email: account.email))
        .accessibilityActions {
            ForEach(row.actions, id: \.self) { action in
                switch action {
                case .useInTerminal:
                    if !model.isChangingAccounts { Button("Use in terminal") { model.useInTerminal(account.id) } }
                case .signIn:
                    Button("Sign in") { model.signInAgain(account) }
                case .rename:
                    Button("Rename", action: startRename)
                case .remove:
                    if !model.isChangingAccounts { Button("Remove", action: askToRemove) }
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ row: AccountRowModel) -> some View {
        switch row.statusTone {
        case .terminal: TerminalTag()
        case .error: Text(row.statusText).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.error)
        case .muted: Text(row.statusText).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted)
        }
    }

    private func actions(_ actions: [AccountRowModel.Action]) -> some View {
        HStack(spacing: 2) {
            ForEach(actions, id: \.self) { action in
                Group {
                    switch action {
                    case .useInTerminal:
                        // Runs through AppModel, off the main thread and never alongside a refresh or a removal.
                        Button("Use in terminal") { model.useInTerminal(account.id) }
                            .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                            .disabled(model.isChangingAccounts)
                    case .signIn:
                        Button("Sign in") { model.signInAgain(account) }
                            .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
                    case .rename:
                        Button("Rename", action: startRename)
                            .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
                    case .remove:
                        Button("Remove", action: askToRemove)
                            .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true, destructive: true))
                            .disabled(model.isChangingAccounts)
                    }
                }
                .focused($focus, equals: .action(action))
            }
        }
        .fixedSize()
    }

    private var removeConfirmation: some View {
        HStack(spacing: 2) {
            Text("Remove \(account.label)?")
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.faint)
                .lineLimit(1)
                .padding(.trailing, 2)
            Group {
                // AppModel refuses the terminal's account with a readable toast.
                Button("Remove") {
                    confirmingRemove = false
                    focus = .row
                    model.remove(account.id)
                }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true, destructive: true))
                .disabled(model.isChangingAccounts)
                .focused($focus, equals: .confirmRemove)
                Button("Cancel") {
                    confirmingRemove = false
                    focus = .action(.remove)
                }
                .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
                .focused($focus, equals: .cancelRemove)
            }
            .fixedSize()
        }
    }

    private var nameField: some View {
        TextField("Label", text: $draft)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .padding(.horizontal, 4)
            .frame(width: 120, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Tok.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(focus == .name ? Tok.claude : Tok.borderStrong,
                                                              lineWidth: 0.5))
            .focused($focus, equals: .name)
            .onAppear { focus = .name }
            .onSubmit(commitRename)
            .onExitCommand {
                renaming = false
                focus = .row
            }
            // Clicking elsewhere keeps the new name, as in the prototype.
            .onChange(of: focus) { old, new in
                if old == .name && new != .name && renaming { commitRename() }
            }
    }

    private func startRename() {
        draft = account.label
        renaming = true
    }

    /// The confirmation replaces the Remove button; keyboard focus moves onto its Remove.
    private func askToRemove() {
        confirmingRemove = true
        focus = .confirmRemove
    }

    private func commitRename() {
        renaming = false
        model.rename(account.id, to: draft)
    }
}
