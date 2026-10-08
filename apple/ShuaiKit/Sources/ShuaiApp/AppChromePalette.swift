import ShuaiTerminal

/// Colors for the app around the terminal, derived from the terminal theme so every surface matches
/// it. The accent is ANSI color 4 (Ristretto's orange, the blue of the Claude themes): it tints icons,
/// selection highlights and buttons. Cards, notices and sheet rows use `elevated`; error, success and
/// warning come from the ANSI red, green and yellow.
public struct AppChromePalette: Equatable, Sendable {
    public var accent: TerminalRGB
    public var surface: TerminalRGB
    /// Cards, notices, sheet rows: the surface lifted toward the text color.
    public var elevated: TerminalRGB
    public var separator: TerminalRGB
    public var text: TerminalRGB
    public var secondaryText: TerminalRGB
    public var selection: TerminalRGB
    public var error: TerminalRGB
    public var success: TerminalRGB
    public var warning: TerminalRGB
    public var prefersDark: Bool

    public init(theme: TerminalTheme) {
        accent = theme.palette[4]
        surface = theme.background
        text = theme.foreground
        elevated = theme.background.blended(with: theme.foreground, fraction: 0.08)
        separator = theme.background.blended(with: theme.foreground, fraction: 0.2)
        secondaryText = theme.foreground.blended(with: theme.background, fraction: 0.3)
        selection = theme.selection
        error = theme.palette[1]
        success = theme.palette[2]
        warning = theme.palette[3]
        prefersDark = theme.isDark
    }
}

extension AppSettings.Theme {
    public var chrome: AppChromePalette { AppChromePalette(theme: terminalTheme) }
}
