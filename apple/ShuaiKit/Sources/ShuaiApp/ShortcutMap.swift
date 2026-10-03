import Foundation

/// Modifier keys of a shortcut (platform neutral; mapped to `UIKeyModifierFlags` by the UI layer).
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

public enum ShortcutKey: Hashable, Sendable {
    /// The character the key produces without modifiers (`"1"`, `"t"`, `"["`).
    case character(String)
    case leftArrow, rightArrow, upArrow, downArrow
    case returnKey
}

public struct KeyChord: Hashable, Sendable {
    public var key: ShortcutKey
    public var modifiers: KeyModifiers

    public init(_ key: ShortcutKey, _ modifiers: KeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    private static let keyNames: [(String, ShortcutKey)] = [
        ("left", .leftArrow), ("right", .rightArrow), ("up", .upArrow), ("down", .downArrow), ("return", .returnKey),
    ]
    private static let modifierNames: [(String, KeyModifiers)] = [
        ("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command),
    ]

    /// Stable text form for config files: `cmd+shift+[`, `cmd+opt+left`.
    public var text: String {
        var parts = Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0)
        switch key {
        case .character(let c): parts.append(c)
        default: parts.append(Self.keyNames.first { $0.1 == key }!.0)
        }
        return parts.joined(separator: "+")
    }

    /// Parses `text`; the key is the last component (a lone `+` key is written `cmd++`).
    public init?(text: String) {
        var rest = Substring(text)
        var mods: KeyModifiers = []
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex || rest.count > 1 {
            let head = rest[..<plus]
            guard let m = Self.modifierNames.first(where: { $0.0 == head }) else { break }
            mods.insert(m.1)
            rest = rest[rest.index(after: plus)...]
        }
        guard !rest.isEmpty else { return nil }
        if let named = Self.keyNames.first(where: { $0.0 == rest }) {
            self.init(named.1, mods)
        } else if rest.count == 1 {
            self.init(.character(String(rest)), mods)
        } else {
            return nil
        }
    }
}

public enum PaneDirection: String, Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

public enum ShortcutAction: Hashable, Sendable {
    /// 1-based position in the window list (not the tmux index: `base-index` may be 0 or 1).
    case selectWindow(position: Int)
    case newWindow, killWindow, previousWindow, nextWindow, lastWindow
    case splitRight, splitDown
    case selectPane(PaneDirection)
    case zoomPane
    case quickSwitcher

    public var id: String {
        switch self {
        case .selectWindow(let n): "selectWindow.\(n)"
        case .newWindow: "newWindow"
        case .killWindow: "killWindow"
        case .previousWindow: "previousWindow"
        case .nextWindow: "nextWindow"
        case .lastWindow: "lastWindow"
        case .splitRight: "splitRight"
        case .splitDown: "splitDown"
        case .selectPane(let d): "selectPane.\(d.rawValue)"
        case .zoomPane: "zoomPane"
        case .quickSwitcher: "quickSwitcher"
        }
    }

    public init?(id: String) {
        if let rest = id.split(separator: ".", maxSplits: 1).last, id.hasPrefix("selectWindow.") {
            guard let n = Int(rest), (1 ... 9).contains(n) else { return nil }
            self = .selectWindow(position: n)
        } else if id.hasPrefix("selectPane.") {
            guard let d = PaneDirection(rawValue: String(id.dropFirst("selectPane.".count))) else { return nil }
            self = .selectPane(d)
        } else if let a = Self.simple.first(where: { $0.id == id }) {
            self = a
        } else {
            return nil
        }
    }

    private static let simple: [ShortcutAction] = [
        .newWindow, .killWindow, .previousWindow, .nextWindow, .lastWindow, .splitRight, .splitDown, .zoomPane,
        .quickSwitcher,
    ]

    public var title: String {
        switch self {
        case .selectWindow(let n): "Window \(n)"
        case .newWindow: "New Window"
        case .killWindow: "Close Window"
        case .previousWindow: "Previous Window"
        case .nextWindow: "Next Window"
        case .lastWindow: "Last Window"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .selectPane(let d): "Select Pane \(d.rawValue.capitalized)"
        case .zoomPane: "Zoom Pane"
        case .quickSwitcher: "Quick Switcher"
        }
    }
}

/// Which chord triggers which action. Defaults live here; a user-configurable layer replaces
/// entries through `overriding`/`removing` and persists the map as JSON.
public struct ShortcutMap: Hashable, Sendable, Codable {
    private var byAction: [String: KeyChord]

    public init(_ bindings: [(ShortcutAction, KeyChord)] = []) {
        byAction = [:]
        for (a, c) in bindings { byAction[a.id] = c }
    }

    /// JSON form: `{"newWindow": "cmd+t", ...}`; unknown actions or unparsable chords are dropped.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        byAction = [:]
        for (id, text) in raw {
            if ShortcutAction(id: id) != nil, let chord = KeyChord(text: text) { byAction[id] = chord }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(byAction.mapValues(\.text))
    }

    public static let defaults: ShortcutMap = {
        var b: [(ShortcutAction, KeyChord)] = (1 ... 9).map {
            (.selectWindow(position: $0), KeyChord(.character(String($0)), [.command]))
        }
        b += [
            (.newWindow, KeyChord(.character("t"), [.command])),
            (.killWindow, KeyChord(.character("w"), [.command, .shift])),
            (.previousWindow, KeyChord(.character("["), [.command, .shift])),
            (.nextWindow, KeyChord(.character("]"), [.command, .shift])),
            (.splitRight, KeyChord(.character("d"), [.command])),
            (.splitDown, KeyChord(.character("d"), [.command, .shift])),
            (.selectPane(.left), KeyChord(.leftArrow, [.command, .option])),
            (.selectPane(.right), KeyChord(.rightArrow, [.command, .option])),
            (.selectPane(.up), KeyChord(.upArrow, [.command, .option])),
            (.selectPane(.down), KeyChord(.downArrow, [.command, .option])),
            (.zoomPane, KeyChord(.returnKey, [.command, .shift])),
            (.quickSwitcher, KeyChord(.character("k"), [.command])),
        ]
        return ShortcutMap(b)
    }()

    /// All bindings in a stable order (by action id).
    public var bindings: [(action: ShortcutAction, chord: KeyChord)] {
        byAction.keys.sorted().compactMap { id in
            ShortcutAction(id: id).flatMap { a in byAction[id].map { (a, $0) } }
        }
    }

    public func chord(for action: ShortcutAction) -> KeyChord? { byAction[action.id] }

    public func action(for chord: KeyChord) -> ShortcutAction? {
        byAction.first { $0.value == chord }.flatMap { ShortcutAction(id: $0.key) }
    }

    /// Binds `chord` to `action`; another action that used the chord becomes unbound.
    public func overriding(_ action: ShortcutAction, with chord: KeyChord) -> ShortcutMap {
        var m = self
        m.byAction = m.byAction.filter { $0.value != chord }
        m.byAction[action.id] = chord
        return m
    }

    public func removing(_ action: ShortcutAction) -> ShortcutMap {
        var m = self
        m.byAction[action.id] = nil
        return m
    }
}
