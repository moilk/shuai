import Foundation

public enum ArrowDirection: Sendable, Hashable {
    case up, down, right, left

    var finalByte: String {
        switch self {
        case .up: "A"
        case .down: "B"
        case .right: "C"
        case .left: "D"
        }
    }
}

/// A logical key, independent of UIKit/Ghostty.
public enum Key: Sendable, Hashable {
    case character(Character)
    case space
    case enter, tab, backspace, escape
    case arrow(ArrowDirection)
    case home, end, pageUp, pageDown, insert, delete
    /// F1...F20.
    case function(Int)
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let ctrl = KeyModifiers(rawValue: 1 << 2)
    /// Command/Super. Never encoded for the remote (app shortcuts).
    public static let meta = KeyModifiers(rawValue: 1 << 3)

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    public var xtermParameter: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.alt) ? 2 : 0) + (contains(.ctrl) ? 4 : 0)
    }
}

public struct KeyStroke: Sendable, Hashable {
    public var key: Key
    public var modifiers: KeyModifiers
    public init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct KeyEncoderOptions: Sendable, Hashable {
    /// DECCKM: arrows/Home/End use SS3 instead of CSI when unmodified.
    public var applicationCursorKeys: Bool
    /// Alt/Option acts as Meta (ESC prefix). When false, Alt adds nothing to text keys.
    public var altSendsEscape: Bool

    public init(applicationCursorKeys: Bool = false, altSendsEscape: Bool = true) {
        self.applicationCursorKeys = applicationCursorKeys
        self.altSendsEscape = altSendsEscape
    }
}

/// xterm-compatible fallback encoder (legacy encoding only). The primary path is Ghostty's own key
/// encoder (`TerminalSurface.sendKey`), which also speaks the kitty keyboard protocol; this is used
/// when no surface is attached and is the reference for the accessory bar.
public enum KeyEncoder {
    private static let esc: UInt8 = 0x1B

    public static func encode(_ stroke: KeyStroke, options: KeyEncoderOptions = .init()) -> Data? {
        let mods = stroke.modifiers
        if mods.contains(.meta) { return nil }
        let altPrefix = mods.contains(.alt) && options.altSendsEscape

        switch stroke.key {
        case let .character(ch):
            return text(ch, mods: mods, altPrefix: altPrefix)
        case .space:
            if mods.contains(.ctrl) { return prefixed([0x00], altPrefix) }
            return prefixed([0x20], altPrefix)
        case .enter:
            return prefixed([0x0D], altPrefix)
        case .tab:
            if mods.contains(.shift) { return Data([esc]) + Data("[Z".utf8) }
            return prefixed([0x09], altPrefix)
        case .backspace:
            return prefixed([mods.contains(.ctrl) ? 0x08 : 0x7F], altPrefix)
        case .escape:
            return prefixed([esc], altPrefix)
        case let .arrow(dir):
            return cursorKey(dir.finalByte, mods: mods, application: options.applicationCursorKeys)
        case .home:
            return cursorKey("H", mods: mods, application: options.applicationCursorKeys)
        case .end:
            return cursorKey("F", mods: mods, application: options.applicationCursorKeys)
        case .insert: return tilde(2, mods)
        case .delete: return tilde(3, mods)
        case .pageUp: return tilde(5, mods)
        case .pageDown: return tilde(6, mods)
        case let .function(n):
            return function(n, mods)
        }
    }

    // MARK: - Helpers

    private static func prefixed(_ bytes: [UInt8], _ alt: Bool) -> Data {
        Data((alt ? [esc] : []) + bytes)
    }

    private static func text(_ ch: Character, mods: KeyModifiers, altPrefix: Bool) -> Data {
        if mods.contains(.ctrl), let control = controlByte(for: ch) {
            return prefixed([control], altPrefix)
        }
        return prefixed(Array(String(ch).utf8), altPrefix)
    }

    private static func controlByte(for ch: Character) -> UInt8? {
        guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
              scalar.isASCII
        else { return nil }
        let v = UInt8(scalar.value)
        switch v {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"): return v - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"): return v - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["): return 0x1B
        case UInt8(ascii: "\\"): return 0x1C
        case UInt8(ascii: "]"): return 0x1D
        case UInt8(ascii: "^"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"): return 0x1F
        case UInt8(ascii: "?"): return 0x7F
        default: return nil
        }
    }

    /// CSI/SS3 + final byte (arrows, Home, End).
    private static func cursorKey(_ final: String, mods: KeyModifiers, application: Bool) -> Data {
        if mods.intersection([.shift, .alt, .ctrl]).isEmpty {
            return Data((application ? "\u{1B}O" : "\u{1B}[").utf8) + Data(final.utf8)
        }
        return Data("\u{1B}[1;\(mods.xtermParameter)\(final)".utf8)
    }

    private static func tilde(_ code: Int, _ mods: KeyModifiers) -> Data {
        if mods.intersection([.shift, .alt, .ctrl]).isEmpty {
            return Data("\u{1B}[\(code)~".utf8)
        }
        return Data("\u{1B}[\(code);\(mods.xtermParameter)~".utf8)
    }

    private static func function(_ n: Int, _ mods: KeyModifiers) -> Data? {
        let unmodified = mods.intersection([.shift, .alt, .ctrl]).isEmpty
        switch n {
        case 1 ... 4:
            let final = ["P", "Q", "R", "S"][n - 1]
            return unmodified
                ? Data("\u{1B}O\(final)".utf8)
                : Data("\u{1B}[1;\(mods.xtermParameter)\(final)".utf8)
        case 5 ... 20:
            let codes = [15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34]
            return tilde(codes[n - 5], mods)
        default:
            return nil
        }
    }
}
