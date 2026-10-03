#if canImport(GhosttyTerminal) && canImport(UIKit)
import GhosttyTerminal

/// Maps our platform-neutral `KeyStroke` to libghostty's key path (`ghostty_surface_key`), whose encoder
/// honours DECCKM, kitty keyboard flags, modifyOtherKeys, etc.
enum GhosttyKeyMapping {
    static func press(for stroke: KeyStroke) -> TerminalKeyPress? {
        guard !stroke.modifiers.contains(.meta) else { return nil }
        var mods: TerminalInputModifiers = []
        if stroke.modifiers.contains(.shift) { mods.insert(.shift) }
        if stroke.modifiers.contains(.ctrl) { mods.insert(.ctrl) }
        if stroke.modifiers.contains(.alt) { mods.insert(.alt) }

        let key: TerminalKey
        switch stroke.key {
        case let .character(c):
            return TerminalKeyPress(typing: c, modifiers: mods)
        case .space: key = .space
        case .enter: key = .enter
        case .tab: key = .tab
        case .backspace: key = .backspace
        case .escape: key = .escape
        case .arrow(.up): key = .arrowUp
        case .arrow(.down): key = .arrowDown
        case .arrow(.left): key = .arrowLeft
        case .arrow(.right): key = .arrowRight
        case .home: key = .home
        case .end: key = .end
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        case .insert: key = .insert
        case .delete: key = .delete
        case let .function(n):
            let keys: [TerminalKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
                                       .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20]
            guard (1 ... 20).contains(n) else { return nil }
            key = keys[n - 1]
        }
        return TerminalKeyPress(key, modifiers: mods)
    }
}
#endif
