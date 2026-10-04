import Foundation
import ShuaiTerminal
import Testing
@testable import ShuaiApp

@Suite struct ShortcutBindingsTests {
    let cmd = TerminalKeyBinding.command
    let shift = TerminalKeyBinding.shift
    let option = TerminalKeyBinding.option

    func binding(_ action: ShortcutAction, in map: ShortcutMap = .defaults) -> TerminalKeyBinding? {
        map.terminalBindings.first { $0.id == action.id }
    }

    @Test func everyDefaultShortcutBecomesABinding() {
        let b = ShortcutMap.defaults.terminalBindings
        #expect(b.count == ShortcutMap.defaults.bindings.count)
        #expect(Set(b.map(\.id)).count == b.count)
    }

    @Test func specShortcuts() {
        #expect(binding(.selectWindow(position: 1)) == TerminalKeyBinding(id: "selectWindow.1", input: "1", modifiers: cmd))
        #expect(binding(.selectWindow(position: 9))?.input == "9")
        #expect(binding(.newWindow) == TerminalKeyBinding(id: "newWindow", input: "t", modifiers: cmd))
        #expect(binding(.killWindow)?.modifiers == cmd | shift)
        #expect(binding(.killWindow)?.input == "w")
        #expect(binding(.previousWindow) == TerminalKeyBinding(id: "previousWindow", input: "[", modifiers: cmd | shift))
        #expect(binding(.nextWindow)?.input == "]")
        #expect(binding(.splitRight)?.modifiers == cmd)
        #expect(binding(.splitDown)?.modifiers == cmd | shift)
        #expect(binding(.quickSwitcher) == TerminalKeyBinding(id: "quickSwitcher", input: "k", modifiers: cmd))
    }

    @Test func arrowsAndReturnUseUIKitKeyInputNames() {
        #expect(binding(.selectPane(.left)) == TerminalKeyBinding(id: "selectPane.left", input: TerminalKeyBinding.leftArrow, modifiers: cmd | option))
        #expect(binding(.selectPane(.up))?.input == TerminalKeyBinding.upArrow)
        #expect(binding(.zoomPane) == TerminalKeyBinding(id: "zoomPane", input: "\r", modifiers: cmd | shift))
        // the strings UIKit documents
        #expect(TerminalKeyBinding.leftArrow == "UIKeyInputLeftArrow")
        #expect(TerminalKeyBinding.rightArrow == "UIKeyInputRightArrow")
        #expect(TerminalKeyBinding.upArrow == "UIKeyInputUpArrow")
        #expect(TerminalKeyBinding.downArrow == "UIKeyInputDownArrow")
    }

    @Test func modifierBitsMatchUIKeyModifierFlags() {
        #expect(TerminalKeyBinding.shift == 1 << 17)
        #expect(TerminalKeyBinding.control == 1 << 18)
        #expect(TerminalKeyBinding.option == 1 << 19)
        #expect(TerminalKeyBinding.command == 1 << 20)
    }

    @Test func overridesAreReflectedAndRemovedOnesDisappear() {
        let map = ShortcutMap.defaults
            .overriding(.newWindow, with: KeyChord(.character("n"), [.command, .option]))
            .removing(.zoomPane)
        #expect(binding(.newWindow, in: map)?.input == "n")
        #expect(binding(.newWindow, in: map)?.modifiers == cmd | option)
        #expect(binding(.zoomPane, in: map) == nil)
    }

    @Test func actionsRoundTripFromTheBindingId() {
        for b in ShortcutMap.defaults.terminalBindings { #expect(ShortcutAction(id: b.id) != nil) }
    }
}
