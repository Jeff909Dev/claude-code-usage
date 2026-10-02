import AppKit
import SwiftUI
import UsageCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Tokens mirrored from prototypes/tokens.css (light / dark).
enum Tok {
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }

    static let bg = dynamic(light: 0xfaf9f5, dark: 0x262624)
    static let surface = dynamic(light: 0xf5f4ed, dark: 0x1f1e1d)
    static let surface2 = dynamic(light: 0xf0eee6, dark: 0x30302e)
    static let surface3 = dynamic(light: 0xe8e6dc, dark: 0x3a3936)
    static let text = dynamic(light: 0x141413, dark: 0xfaf9f5)
    static let text2 = dynamic(light: 0x3d3d3a, dark: 0xc2c0b6)
    static let muted = dynamic(light: 0x73726c, dark: 0x9c9a92)
    static let faint = dynamic(light: 0xa3a19a, dark: 0x6b6a65)
    static let border = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.12, darkAlpha: 0.12)
    static let borderStrong = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.22, darkAlpha: 0.22)
    static let track = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.08, darkAlpha: 0.10)
    static let claude = dynamic(light: 0xc96442, dark: 0xd97757)
    static let claudeStrong = Color(nsColor: NSColor(hex: 0xc96442))
    static let claudeTint = dynamic(light: 0xc96442, dark: 0xd97757, lightAlpha: 0.10, darkAlpha: 0.14)
    static let success = dynamic(light: 0x2f8f46, dark: 0x4eba65)
    static let warning = dynamic(light: 0xb7791f, dark: 0xe5a83b)
    static let error = dynamic(light: 0xc4314b, dark: 0xff6b80)
    static let suggestion = dynamic(light: 0x5865c9, dark: 0xb1b9f9)
    static let plan = Color(nsColor: NSColor(hex: 0x48968c))

    static func level(_ level: UsageLevel) -> Color {
        switch level {
        case .normal: return claude
        case .warn: return warning
        case .critical: return error
        }
    }

    static func avatar(_ index: Int) -> Color { Color(nsColor: NSColor(hex: AccountPalette.hex(for: index))) }
}

enum Typo {
    static func ui(_ style: ThemeStyle, size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        style == .cli ? .system(size: size, weight: weight, design: .monospaced) : .system(size: size + 1, weight: weight)
    }

    static func num(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }

    static func serif(size: CGFloat = 18) -> Font { .system(size: size, design: .serif) }
}

private struct ThemeStyleKey: EnvironmentKey {
    static let defaultValue = ThemeStyle.cli
}

extension EnvironmentValues {
    var themeStyle: ThemeStyle {
        get { self[ThemeStyleKey.self] }
        set { self[ThemeStyleKey.self] = newValue }
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}
