import SwiftUI
import UsageCore

struct LimitsSection: View {
    let account: Account
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        let section = LimitsSectionModel.make(state: model.state(for: account.id), isRefreshing: model.isRefreshing,
                                              now: now, calendar: .current)
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "limits", trailing: section.note)
                .padding(.bottom, 8)
            if let problem = model.pollError {
                Notice(title: problem).padding(.bottom, 10)
            }
            if section.needsSignIn {
                Notice(title: "Session expired — sign in again", detail: section.signInDetail,
                       actionTitle: "Sign in") { model.signInAgain(account) }
                    .padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.rows) { LimitRow(row: $0) }
            }
            switch section.placeholder {
            case .loading:
                HStack(spacing: 6) {
                    Spinner()
                    Text("loading limits…").foregroundStyle(Tok.muted)
                }
            case .message(let text):
                Text(text).foregroundStyle(Tok.faint)
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct LimitRow: View {
    let row: LimitRowModel
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .foregroundStyle(row.isDimmed ? Tok.muted : Tok.text)
                        .layoutPriority(1)
                    if let reset = row.resetText {
                        Text(reset).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Text(row.percentText)
                    .font(Typo.num(size: style == .cli ? 11 : 12, weight: .semibold))
                    .foregroundStyle(percentColor)
            }
            .padding(.bottom, 4)
            UsageBar(percent: row.percent, paceFraction: row.paceFraction, level: row.level, dimmed: row.isDimmed)
            if !row.note.isEmpty {
                HStack(spacing: 4) {
                    Text("⎿").foregroundStyle(Tok.faint)
                    Text(row.note).foregroundStyle(noteColor)
                }
                .font(Typo.ui(style, size: 10))
                .lineLimit(1)
                .padding(.top, 3)
            }
        }
    }

    private var percentColor: Color {
        if row.isDimmed { return Tok.muted }
        switch row.level {
        case .normal: return Tok.text
        case .warn: return Tok.warning
        case .critical: return Tok.error
        }
    }

    private var noteColor: Color {
        switch row.noteTone {
        case .muted: return Tok.muted
        case .faint: return Tok.faint
        case .warning: return Tok.warning
        case .error: return Tok.error
        }
    }
}

/// Shown only when another account has more headroom than the terminal's (Recommender.best).
struct BestAccountCallout: View {
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "best account now")
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text("❯ ").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tok.claude))\(Text(account.label).fontWeight(.semibold)) has the most headroom")
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text(model.headroomLine(for: account))
                        .font(Typo.num(size: 10))
                        .foregroundStyle(Tok.muted)
                        .lineLimit(1)
                        .padding(.leading, 14)
                    Spacer(minLength: 0)
                    // Switching runs through AppModel, off the main thread and never alongside a refresh.
                    Button(model.isSwitching ? "Switching…" : "Use in terminal") { model.useInTerminal(account.id) }
                        .buttonStyle(ClaudeButtonStyle(kind: .primary, compact: true))
                        .disabled(model.isChangingAccounts)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.claudeTint))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.claude.opacity(0.3), lineWidth: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
