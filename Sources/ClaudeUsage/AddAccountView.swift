import AppKit
import SwiftUI
import UsageCore

/// Mirrors claude.ai's sign-in: both buttons run Claude Code's own `claude auth login` (spec §7).
struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.themeStyle) private var style
    @State private var email = ""
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Leaving cancels a sign-in that is still waiting for the browser.
            NavHeader(title: "Accounts") {
                model.cancelAddAccount()
                model.route = .settings
            }
            Hairline()
            // The form starts under the header, as in the prototype; waiting and success sit mid-popover.
            switch model.addState {
            case .idle, .failed: form
            case .waiting(let method): waiting(method)
            case .success(let email, let plan): added(email: email, plan: plan)
            }
        }
        .font(Typo.ui(style))
        .foregroundStyle(Tok.text)
        .onAppear { if email.isEmpty { email = model.addPrefillEmail } }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Text("✻").font(.system(size: 26, design: .monospaced)).foregroundStyle(Tok.claude)
            Text("Add a Claude account")
                .font(Typo.serif(size: 19))
                .padding(.top, 10)
                .padding(.bottom, 4)
            Text("Sign in on claude.ai — Claude Code's official login. Works with Google or email.")
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            Group {
                Button { model.addAccount(.google) } label: {
                    HStack(spacing: 6) {
                        GoogleMark().frame(width: 14, height: 14)
                        Text("Continue with Google")
                    }
                }
                .buttonStyle(ClaudeButtonStyle(kind: .secondary, fullWidth: true))
                HStack(spacing: 8) {
                    Hairline()
                    Text("or").font(Typo.ui(style, size: 10)).foregroundStyle(Tok.faint)
                    Hairline()
                }
                .padding(.vertical, 10)
                emailField.padding(.bottom, 6)
                Button("Continue with email", action: continueWithEmail)
                    .buttonStyle(ClaudeButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(EmailAddress.validated(email) == nil)
            }
            .disabled(model.readOnly)
            if model.readOnly {
                Notice(title: AppModel.readOnlyNote).padding(.top, 10)
            } else if case .failed(let message) = model.addState {
                Notice(title: message).padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Your browser authorizes whichever claude.ai account is signed in there — switch it first with the Claude Account Switcher extension.")
                    .foregroundStyle(Tok.muted)
                Text("Each account gets its own credential slot in Keychain. Your \(Text("~/.claude").font(.system(size: 10, design: .monospaced))) settings, history and plugins stay shared.")
                    .foregroundStyle(Tok.faint)
            }
            .font(Typo.ui(style, size: 10))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 14, trailing: 20))
    }

    private var emailField: some View {
        TextField("", text: $email)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .focused($emailFocused)
            .onSubmit(continueWithEmail)
            .accessibilityLabel("Email")
            // macOS draws a TextField's prompt in its own colour; this one follows the theme.
            .background(alignment: .leading) {
                if email.isEmpty { Text(verbatim: "name@example.com").foregroundStyle(Tok.faint).allowsHitTesting(false) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.surface))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(emailFocused ? Tok.claude : Tok.borderStrong, lineWidth: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Tok.claudeTint, lineWidth: 2).padding(-1)
                .opacity(emailFocused ? 1 : 0))
    }

    private func waiting(_ method: LoginMethod) -> some View {
        VStack(spacing: 0) {
            Spinner(size: 22)
            Text("Waiting for sign-in…").fontWeight(.semibold).padding(.top, 12)
            detail(for: method)
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 14)
            Button("Cancel") { model.cancelAddAccount() }
                .buttonStyle(ClaudeButtonStyle(kind: .ghost, compact: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: 28, leading: 20, bottom: 18, trailing: 20))
    }

    private func detail(for method: LoginMethod) -> Text {
        switch method {
        case .google:
            return Text("Finish signing in with Google in your browser.")
        case .email(let address):
            return Text("Continue in your browser — claude.ai emails a magic link to \(Text(address).foregroundStyle(Tok.text2)). Open it to finish.")
        }
    }

    /// A sign-in again of an account already listed (even the terminal's) lands here too.
    private func added(email: String, plan: String) -> some View {
        VStack(spacing: 0) {
            Text("✓").font(.system(size: 22, design: .monospaced)).foregroundStyle(Tok.success)
            Text("Added \(email) · \(plan)")
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Text("Usage will appear in the menu bar within a minute.")
                .font(Typo.ui(style, size: 10))
                .foregroundStyle(Tok.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(EdgeInsets(top: 28, leading: 20, bottom: 18, trailing: 20))
    }

    private func continueWithEmail() {
        guard !model.readOnly, let address = EmailAddress.validated(email) else { return }
        model.addAccount(.email(address))
    }
}

/// Google's "G" from the prototype's SVG, drawn in its 48 × 48 box.
private struct GoogleMark: View {
    private enum Segment {
        case line(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }

    private static let pieces: [(color: UInt32, start: CGPoint, segments: [Segment])] = [
        (0xEA4335, CGPoint(x: 24, y: 9.5), [
            .curve(27.54, 9.5, 30.71, 10.72, 33.21, 13.1), .line(40.06, 6.25), .curve(35.9, 2.38, 30.47, 0, 24, 0),
            .curve(14.62, 0, 6.51, 5.38, 2.56, 13.22), .line(10.54, 19.41), .curve(12.43, 13.72, 17.74, 9.5, 24, 9.5),
        ]),
        (0x4285F4, CGPoint(x: 46.98, y: 24.55), [
            .curve(46.98, 22.98, 46.83, 21.46, 46.6, 20), .line(24, 20), .line(24, 29.02), .line(36.94, 29.02),
            .curve(36.36, 31.98, 34.68, 34.5, 32.16, 36.2), .line(39.89, 42.2),
            .curve(44.4, 38.02, 46.98, 31.84, 46.98, 24.55),
        ]),
        (0xFBBC05, CGPoint(x: 10.53, y: 28.59), [
            .curve(10.05, 27.14, 9.77, 25.6, 9.77, 24), .curve(9.77, 22.4, 10.04, 20.86, 10.53, 19.41),
            .line(2.55, 13.22), .curve(0.92, 16.46, 0, 20.12, 0, 24), .curve(0, 27.88, 0.92, 31.54, 2.56, 34.78),
        ]),
        (0x34A853, CGPoint(x: 24, y: 48), [
            .curve(30.48, 48, 35.93, 45.87, 39.89, 42.19), .line(32.16, 36.19),
            .curve(30.01, 37.64, 27.24, 38.49, 24, 38.49), .curve(17.74, 38.49, 12.43, 34.27, 10.53, 28.58),
            .line(2.55, 34.77), .curve(6.51, 42.62, 14.62, 48, 24, 48),
        ]),
    ]

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 48, y: size.height / 48)
            for piece in Self.pieces {
                var path = Path()
                path.move(to: piece.start)
                for segment in piece.segments {
                    switch segment {
                    case .line(let x, let y):
                        path.addLine(to: CGPoint(x: x, y: y))
                    case .curve(let x1, let y1, let x2, let y2, let x, let y):
                        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                                      control2: CGPoint(x: x2, y: y2))
                    }
                }
                path.closeSubpath()
                context.fill(path, with: .color(Color(nsColor: NSColor(hex: piece.color))))
            }
        }
        .accessibilityHidden(true)
    }
}
