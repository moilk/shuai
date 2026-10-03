import Foundation

public enum StickyState: Sendable, Equatable {
    case off
    /// Applies to the next key only.
    case oneShot
    /// Stays on until tapped again (double tap on the button).
    case locked
}

public enum AccessoryButton: Sendable, Hashable {
    case esc, tab, ctrl, alt
    case up, down, left, right
    case symbol(Character)
    // Claude Code strip. Mapping against Claude Code's permission dialog
    // ("1. Yes / 2. Yes, and don't ask again ... / 3. No, and tell Claude what to do differently (esc)"):
    //  - Yes    -> "1": always the first option, selects immediately.
    //  - Always -> "2": the second option. In two-option dialogs (Yes/No) "2" is No, i.e. the failure mode
    //              is a denial, never an unintended approval.
    //  - No     -> Esc, NOT "3": Esc is the dialog's own cancel ("(esc)") in every dialog regardless of
    //              how many options it has, and can never select an approval. "3" would do nothing in a
    //              2-option dialog and cannot be the same key everywhere.
    // Outside a dialog "1"/"2" are typed into the prompt as text (harmless, visible).
    case claudeYes, claudeAlways, claudeNo, claudeModeCycle, claudeInterrupt, claudeCtrlC, claudeSlash

    public static let standardRow: [AccessoryButton] = [
        .esc, .ctrl, .alt, .tab, .up, .down, .left, .right,
        .symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"),
    ]

    public static let claudeStrip: [AccessoryButton] = [
        .claudeYes, .claudeAlways, .claudeNo, .claudeModeCycle, .claudeInterrupt, .claudeCtrlC, .claudeSlash,
    ]

    public var isClaudeButton: Bool { Self.claudeStrip.contains(self) }

    /// Short label for the bar.
    public var title: String {
        switch self {
        case .esc: "Esc"
        case .tab: "Tab"
        case .ctrl: "Ctrl"
        case .alt: "Alt"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case let .symbol(c): String(c)
        case .claudeYes: "Yes"
        case .claudeAlways: "Always"
        case .claudeNo: "No"
        case .claudeModeCycle: "⇧Tab"
        case .claudeInterrupt: "Esc"
        case .claudeCtrlC: "^C"
        case .claudeSlash: "/"
        }
    }
}

/// Pure state of the keyboard accessory bar: sticky Ctrl/Alt and button -> key strokes.
public struct AccessoryBarModel: Sendable, Equatable {
    public private(set) var ctrl: StickyState = .off
    public private(set) var alt: StickyState = .off

    public init() {}

    public var hasActiveModifiers: Bool { ctrl != .off || alt != .off }

    public static func isRepeatable(_ button: AccessoryButton) -> Bool {
        switch button {
        case .up, .down, .left, .right: true
        default: false
        }
    }

    public func state(of button: AccessoryButton) -> StickyState {
        switch button {
        case .ctrl: ctrl
        case .alt: alt
        default: .off
        }
    }

    public mutating func reset() {
        ctrl = .off
        alt = .off
    }

    /// Handles a tap. Modifier buttons toggle and return no strokes; other buttons return the strokes to send.
    public mutating func press(_ button: AccessoryButton, at now: Date = Date()) -> [KeyStroke] {
        switch button {
        case .ctrl:
            ctrl = Self.next(ctrl, lastTap: lastCtrlTap, now: now)
            lastCtrlTap = now
            return []
        case .alt:
            alt = Self.next(alt, lastTap: lastAltTap, now: now)
            lastAltTap = now
            return []
        case .claudeYes: return [KeyStroke(.character("1"))]
        case .claudeAlways: return [KeyStroke(.character("2"))]
        case .claudeNo, .claudeInterrupt: return [KeyStroke(.escape)]
        case .claudeModeCycle: return [KeyStroke(.tab, .shift)]
        case .claudeCtrlC: return [KeyStroke(.character("c"), .ctrl)]
        case .claudeSlash: return [KeyStroke(.character("/"))]
        case .esc: return [apply(to: KeyStroke(.escape))]
        case .tab: return [apply(to: KeyStroke(.tab))]
        case .up: return [apply(to: KeyStroke(.arrow(.up)))]
        case .down: return [apply(to: KeyStroke(.arrow(.down)))]
        case .left: return [apply(to: KeyStroke(.arrow(.left)))]
        case .right: return [apply(to: KeyStroke(.arrow(.right)))]
        case let .symbol(c): return [apply(to: KeyStroke(.character(c)))]
        }
    }

    /// Adds armed sticky modifiers to a stroke (e.g. typed on the software keyboard) and spends one-shots.
    public mutating func apply(to stroke: KeyStroke) -> KeyStroke {
        var out = stroke
        if ctrl != .off { out.modifiers.insert(.ctrl) }
        if alt != .off { out.modifiers.insert(.alt) }
        if ctrl == .oneShot { ctrl = .off }
        if alt == .oneShot { alt = .off }
        return out
    }

    /// Strokes for `button` encoded with the fallback `KeyEncoder`.
    public mutating func bytes(for button: AccessoryButton, options: KeyEncoderOptions = .init()) -> Data {
        press(button).reduce(into: Data()) { acc, stroke in
            if let d = KeyEncoder.encode(stroke, options: options) { acc.append(d) }
        }
    }

    /// Adopts state held elsewhere (the terminal view's own sticky tracking after a typed key spent it).
    public mutating func sync(ctrl: StickyState, alt: StickyState) {
        self.ctrl = ctrl
        self.alt = alt
    }

    public static let doubleTapInterval: TimeInterval = 0.3
    private var lastCtrlTap: Date = .distantPast
    private var lastAltTap: Date = .distantPast

    /// off -> one-shot; a second tap inside the double-tap window locks, a slower one cancels; locked -> off.
    private static func next(_ s: StickyState, lastTap: Date, now: Date) -> StickyState {
        switch s {
        case .off: .oneShot
        case .oneShot: now.timeIntervalSince(lastTap) < doubleTapInterval ? .locked : .off
        case .locked: .off
        }
    }
}
