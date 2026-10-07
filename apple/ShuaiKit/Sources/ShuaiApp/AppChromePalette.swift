import ShuaiTerminal

/// Colors for the app around the terminal, derived from the terminal theme so the sidebar, bars and
/// sheets match it. The accent is ANSI color 4 (Ristretto's orange, the blue of the Claude themes):
/// it tints icons, selection highlights and buttons.
public struct AppChromePalette: Equatable, Sendable {
    public var accent: TerminalRGB
    public var surface: TerminalRGB
    public var text: TerminalRGB
    public var prefersDark: Bool

    public init(theme: TerminalTheme) {
        accent = theme.palette[4]
        surface = theme.background
        text = theme.foreground
        prefersDark = theme.isDark
    }
}

extension AppSettings.Theme {
    public var chrome: AppChromePalette { AppChromePalette(theme: terminalTheme) }
}
