import Foundation

/// 8-bit sRGB color with WCAG 2.x contrast math.
public struct TerminalRGB: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    /// `#RRGGBB` (what Ghostty's config accepts).
    public var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// WCAG relative luminance (0 = black, 1 = white).
    public var relativeLuminance: Double {
        func lin(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio, 1...21, symmetric.
    public static func contrastRatio(_ a: TerminalRGB, _ b: TerminalRGB) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Terminal colors. The terminal never follows the system appearance: the app picks a theme
/// (default Monokai Pro Ristretto, user-selectable) and the engine applies it as both the light and the
/// dark Ghostty variant.
public struct TerminalTheme: Sendable, Hashable, Identifiable {
    public var name: String
    public var isDark: Bool
    public var foreground: TerminalRGB
    public var background: TerminalRGB
    public var cursor: TerminalRGB
    public var selection: TerminalRGB
    /// ANSI colors 0-15 (0-7 normal, 8-15 bright).
    public var palette: [TerminalRGB]

    public var id: String { name }

    public init(
        name: String, isDark: Bool, foreground: TerminalRGB, background: TerminalRGB,
        cursor: TerminalRGB, selection: TerminalRGB, palette: [TerminalRGB]
    ) {
        precondition(palette.count == 16, "palette must have 16 colors")
        self.name = name
        self.isDark = isDark
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.palette = palette
    }

    public static let `default`: TerminalTheme = .monokaiProRistretto
    public static let builtIn: [TerminalTheme] = [.monokaiProRistretto, .claudeDark, .claudeLight]

    /// Monokai Pro Ristretto as in the Ghostty theme at github.com/Kirlovon/monokai-ghostty; bright black
    /// is lifted from #72696A so Claude Code's dim grey keeps a contrast of 3 or more.
    public static let monokaiProRistretto = TerminalTheme(
        name: "Monokai Pro Ristretto", isDark: true,
        foreground: TerminalRGB(hex: 0xFFF1F3), background: TerminalRGB(hex: 0x2C2525),
        cursor: TerminalRGB(hex: 0xC3B7B8), selection: TerminalRGB(hex: 0x5B5353),
        palette: [
            0x2C2525, 0xFD6883, 0xADDA78, 0xF9CC6C, 0xF38D70, 0xA8A9EB, 0x85DACC, 0xFFF1F3,
            0x7A7172, 0xFD6883, 0xADDA78, 0xF9CC6C, 0xF38D70, 0xA8A9EB, 0x85DACC, 0xFFF1F3,
        ].map(TerminalRGB.init(hex:))
    )

    /// Catppuccin Mocha derived; bright black lifted to overlay1 so Claude Code's dim grey stays legible.
    public static let claudeDark = TerminalTheme(
        name: "Claude Dark", isDark: true,
        foreground: TerminalRGB(hex: 0xCDD6F4), background: TerminalRGB(hex: 0x1E1E2E),
        cursor: TerminalRGB(hex: 0xF5E0DC), selection: TerminalRGB(hex: 0x45475A),
        palette: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x7F849C, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xCDD6F4,
        ].map(TerminalRGB.init(hex:))
    )

    /// GitHub-light inspired: every chromatic color is darkened so blues stay readable on white.
    public static let claudeLight = TerminalTheme(
        name: "Claude Light", isDark: false,
        foreground: TerminalRGB(hex: 0x24292F), background: TerminalRGB(hex: 0xFFFFFF),
        cursor: TerminalRGB(hex: 0x0550AE), selection: TerminalRGB(hex: 0xC8E1FF),
        palette: [
            0x24292F, 0xCF222E, 0x1A7F37, 0x7D4E00, 0x0550AE, 0x8250DF, 0x1B7C83, 0x57606A,
            0x6E7781, 0xA40E26, 0x116329, 0x633C01, 0x0969DA, 0x6639BA, 0x1B7C83, 0x424A53,
        ].map(TerminalRGB.init(hex:))
    )
}
