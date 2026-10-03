import Foundation

/// Hardware keyboard Option -> Alt (Meta) mapping.
///
/// UIKit delivers Option+b as `characters == "∫"` with `charactersIgnoringModifiers == "b"`. libghostty's
/// UIKit key path forwards the composed text and marks Alt as consumed, so unless Ghostty's
/// `macos-option-as-alt` takes effect on the iOS embedding (it is Zig-side and not verifiable from the
/// Swift package: the config key is accepted, nothing in the Swift layer reads it) the remote would get
/// "∫" instead of ESC b (readline/Claude Code word motions). `TerminalView` therefore maps these chords
/// itself with this rule and sends them through the engine's key encoder.
public enum OptionAsAlt {
    /// `base` is `UIKey.charactersIgnoringModifiers` (shift is preserved in it).
    /// Returns nil when Ghostty should handle the press (no Option, Ctrl/Cmd chords, function/navigation
    /// keys, anything that is not exactly one printable character).
    public static func stroke(base: String, shift _: Bool, control: Bool, command: Bool, option: Bool) -> KeyStroke? {
        guard option, !control, !command else { return nil }
        let scalars = Array(base.unicodeScalars)
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        let v = scalar.value
        // C0 controls, DEL, C1 controls, and the private-use block UIKit uses for arrows/F-keys/Home/End.
        guard v >= 0x20, v != 0x7F, !(0x80 ... 0x9F).contains(v), !(0xE000 ... 0xF8FF).contains(v) else { return nil }
        return KeyStroke(.character(Character(scalar)), .alt)
    }
}
