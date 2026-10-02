import SwiftUI
import UsageCore

/// A lowercase section label, with an optional faint note on the right.
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).foregroundStyle(Tok.muted)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).foregroundStyle(Tok.faint).lineLimit(1) }
        }
        .font(Typo.ui(style, size: 10))
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Tok.border).frame(height: 0.5) }
}

struct AvatarView: View {
    let account: Account
    var size: CGFloat = 22

    var body: some View {
        Text(String(account.label.prefix(1)).uppercased())
            .font(.system(size: max(8, size * 0.45), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Tok.avatar(account.colorIndex)))
    }
}

struct Badge: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(accent ? Tok.claude : Tok.text2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(accent ? Tok.claudeTint : Tok.surface2))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent ? Color.clear : Tok.border, lineWidth: 0.5))
    }
}

struct TerminalTag: View {
    var body: some View {
        Text("● terminal").font(.system(size: 10, design: .monospaced)).foregroundStyle(Tok.claude)
    }
}

/// A thin usage bar; the pace marker shows how much of the window has elapsed.
struct UsageBar: View {
    let percent: Double
    let paceFraction: Double?
    let level: UsageLevel
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            RoundedRectangle(cornerRadius: 3).fill(Tok.track)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(dimmed ? Tok.faint : Tok.level(level))
                        .frame(width: width * min(max(percent, 0), 100) / 100)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(alignment: .leading) {
                    if let paceFraction {
                        Rectangle().fill(Tok.text2.opacity(0.7))
                            .frame(width: 1.5, height: 10)
                            .offset(x: min(max(width * paceFraction - 0.75, 0), width - 1.5))
                    }
                }
        }
        .frame(height: 6)
    }
}

struct ClaudeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind = Kind.secondary
    var fullWidth = false
    /// 22 pt tall with small text, for buttons inside rows, notices and callouts.
    var compact = false
    /// Error-coloured text, for removing things.
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        ClaudeButton(configuration: configuration, kind: kind, fullWidth: fullWidth, compact: compact,
                     destructive: destructive)
    }
}

private struct ClaudeButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: ClaudeButtonStyle.Kind
    let fullWidth: Bool
    let compact: Bool
    let destructive: Bool
    @Environment(\.themeStyle) private var style
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8)
        configuration.label
            .font(Typo.ui(style, size: compact ? 10 : 11, weight: kind == .primary ? .medium : .regular))
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: compact ? 22 : (fullWidth ? 32 : 26))
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.stroke(kind == .secondary ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }

    private var lit: Bool { hovering && isEnabled }

    private var foreground: Color {
        if destructive && kind != .primary { return Tok.error }
        switch kind {
        case .primary: return .white
        case .secondary: return Tok.text
        case .ghost: return lit ? Tok.text : Tok.text2
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Tok.claudeStrong.opacity(configuration.isPressed ? 0.85 : 1)
        case .secondary: return configuration.isPressed || lit ? Tok.surface3 : Tok.surface2
        case .ghost: return configuration.isPressed || lit ? Tok.surface2 : Color.clear
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    /// Turns the symbol while work it started is running.
    var isSpinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !isSpinning)) { context in
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .rotationEffect(.degrees(isSpinning ? context.date.timeIntervalSinceReferenceDate * 450 : 0))
            }
            .foregroundStyle(hovering ? Tok.text : Tok.muted)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Tok.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(Typo.ui(style, size: 10))
                        .foregroundStyle(selected ? Tok.text : Tok.muted)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Tok.bg : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Tok.borderStrong : Color.clear, lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.border, lineWidth: 0.5))
    }
}

/// The CLI's ✻ spinner.
struct Spinner: View {
    var size: CGFloat = 12
    private let frames = ["✻", "✽", "✶", "✳"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(frames[Int(context.date.timeIntervalSinceReferenceDate * 4) % frames.count])
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(Tok.claude)
        }
    }
}

/// An error-tinted box: what went wrong, an optional detail line and an optional action.
struct Notice: View {
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.themeStyle) private var style

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Tok.error).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Typo.ui(style, size: 10)).foregroundStyle(Tok.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(ClaudeButtonStyle(kind: .secondary, compact: true))
            }
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.error.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.error.opacity(0.35), lineWidth: 0.5))
    }
}

/// The top bar of a sub-view: "‹ Title" goes back.
struct NavHeader: View {
    let title: String
    let action: () -> Void
    @Environment(\.themeStyle) private var style
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text("‹").foregroundStyle(Tok.muted)
                    Text(title).fontWeight(.semibold)
                }
                .font(Typo.ui(style, size: 12))
                .foregroundStyle(Tok.text)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Tok.surface2 : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 8))
    }
}
