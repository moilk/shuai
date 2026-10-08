import ShuaiTerminal
import SwiftUI

/// SwiftUI side of `AppChromePalette`: an environment value, shape styles for the palette's roles and
/// the modifiers that give every surface the same colors. Views never pick system colors for chrome.
private struct ChromePaletteKey: EnvironmentKey {
    static let defaultValue = AppSettings.Theme.ristretto.chrome
}

extension EnvironmentValues {
    public var chrome: AppChromePalette {
        get { self[ChromePaletteKey.self] }
        set { self[ChromePaletteKey.self] = newValue }
    }
}

extension Color {
    public init(_ rgb: TerminalRGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

/// A palette role as a `ShapeStyle`, resolved from the environment: `.foregroundStyle(.chromeSecondary)`.
public struct ChromeStyle: ShapeStyle {
    public enum Role: Sendable { case surface, elevated, separator, text, secondary, accent, error, success, warning, selection }
    let role: Role

    public func resolve(in environment: EnvironmentValues) -> Color {
        let p = environment.chrome
        switch role {
        case .surface: return Color(p.surface)
        case .elevated: return Color(p.elevated)
        case .separator: return Color(p.separator)
        case .text: return Color(p.text)
        case .secondary: return Color(p.secondaryText)
        case .accent: return Color(p.accent)
        case .error: return Color(p.error)
        case .success: return Color(p.success)
        case .warning: return Color(p.warning)
        case .selection: return Color(p.selection)
        }
    }
}

extension ShapeStyle where Self == ChromeStyle {
    public static var chromeSurface: ChromeStyle { ChromeStyle(role: .surface) }
    public static var chromeElevated: ChromeStyle { ChromeStyle(role: .elevated) }
    public static var chromeSeparator: ChromeStyle { ChromeStyle(role: .separator) }
    public static var chromeText: ChromeStyle { ChromeStyle(role: .text) }
    public static var chromeSecondary: ChromeStyle { ChromeStyle(role: .secondary) }
    public static var chromeAccent: ChromeStyle { ChromeStyle(role: .accent) }
    public static var chromeError: ChromeStyle { ChromeStyle(role: .error) }
    public static var chromeSuccess: ChromeStyle { ChromeStyle(role: .success) }
    public static var chromeWarning: ChromeStyle { ChromeStyle(role: .warning) }
    public static var chromeSelection: ChromeStyle { ChromeStyle(role: .selection) }
}

/// A row or card background that follows the palette (for `.listRowBackground`).
public struct ChromeRowBackground: View {
    public init() {}
    public var body: some View { Rectangle().fill(.chromeElevated) }
}

extension View {
    /// The root of a window or a sheet: palette, tint, appearance, text color and surface.
    public func chromeRoot(_ palette: AppChromePalette) -> some View {
        environment(\.chrome, palette)
            .tint(Color(palette.accent))
            .preferredColorScheme(palette.prefersDark ? .dark : .light)
            .foregroundStyle(Color(palette.text))
    }

    /// A `Form` or `List` on the surface with palette rows and navigation bar.
    public func chromeForm() -> some View {
        let base = scrollContentBackground(.hidden)
            .background(.chromeSurface)
            .listRowBackground(ChromeRowBackground())
        #if os(iOS)
        return base.toolbarBackground(.chromeSurface, for: .navigationBar)
        #else
        return base
        #endif
    }

    /// A floating card: notices, permission cards, connection cards.
    public func chromeCard(cornerRadius: CGFloat) -> some View {
        background(.chromeElevated, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.chromeSeparator, lineWidth: 1))
    }
}
