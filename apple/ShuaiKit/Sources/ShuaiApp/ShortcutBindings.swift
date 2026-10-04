import Foundation
import ShuaiTerminal

extension KeyChord {
    /// The UIKit form: unmodified character or `UIKeyInput*` name plus `UIKeyModifierFlags` bits.
    public var terminalInput: (input: String, modifiers: Int) {
        let input: String
        switch key {
        case .character(let c): input = c
        case .leftArrow: input = TerminalKeyBinding.leftArrow
        case .rightArrow: input = TerminalKeyBinding.rightArrow
        case .upArrow: input = TerminalKeyBinding.upArrow
        case .downArrow: input = TerminalKeyBinding.downArrow
        case .returnKey: input = "\r"
        }
        var m = 0
        if modifiers.contains(.shift) { m |= TerminalKeyBinding.shift }
        if modifiers.contains(.control) { m |= TerminalKeyBinding.control }
        if modifiers.contains(.option) { m |= TerminalKeyBinding.option }
        if modifiers.contains(.command) { m |= TerminalKeyBinding.command }
        return (input, m)
    }
}

extension ShortcutMap {
    /// Key commands for the terminal view, one per bound action (binding id == `ShortcutAction.id`).
    public var terminalBindings: [TerminalKeyBinding] {
        bindings.map { action, chord in
            let t = chord.terminalInput
            return TerminalKeyBinding(id: action.id, input: t.input, modifiers: t.modifiers)
        }
    }
}
