import Foundation

/// Which accessory bar to show: the docked `inputAccessoryView` above the software keyboard, or
/// the compact floating bar (hardware keyboard, no software keyboard on screen).
///
/// The inputs deliberately exclude anything our own choice can change: a hardware keyboard
/// connected/disconnected (GameController notifications) and whether a *tall* keyboard frame is up.
/// The docked bar alone produces a short keyboard frame, so reloading input views never flips the
/// decision (no feedback loop).
public enum AccessoryBarPlacement: Sendable, Equatable {
    case docked, floating

    /// Frames shorter than this are accessory-only (docked bar / iPadOS shortcut bar), not keys.
    public static let softwareKeyboardMinHeight: Double = 200

    public static func isSoftwareKeyboard(frameHeight: Double) -> Bool {
        frameHeight >= softwareKeyboardMinHeight
    }

    public static func decide(hardwareKeyboard: Bool, preferFloating: Bool, softwareKeyboardVisible: Bool) -> AccessoryBarPlacement {
        if preferFloating { return .floating }
        return hardwareKeyboard && !softwareKeyboardVisible ? .floating : .docked
    }
}
