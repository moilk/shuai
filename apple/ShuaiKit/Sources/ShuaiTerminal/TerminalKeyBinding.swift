import Foundation

/// A hardware shortcut the host app wants delivered while the terminal has focus (platform
/// neutral; `TerminalView` turns it into a `UIKeyCommand`). `modifiers` uses the raw values of
/// `UIKeyModifierFlags` and `input` is the key's unmodified character or one of the `UIKeyInput*`
/// names, so no UIKit import is needed to build bindings.
public struct TerminalKeyBinding: Equatable, Hashable, Sendable {
    public var id: String
    public var input: String
    public var modifiers: Int

    public init(id: String, input: String, modifiers: Int) {
        self.id = id
        self.input = input
        self.modifiers = modifiers
    }

    public static let shift = 1 << 17
    public static let control = 1 << 18
    public static let option = 1 << 19
    public static let command = 1 << 20

    public static let leftArrow = "UIKeyInputLeftArrow"
    public static let rightArrow = "UIKeyInputRightArrow"
    public static let upArrow = "UIKeyInputUpArrow"
    public static let downArrow = "UIKeyInputDownArrow"
}
