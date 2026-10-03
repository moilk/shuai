#if canImport(GhosttyTerminal) && canImport(UIKit)
import Testing
import UIKit
@testable import ShuaiTerminal

@MainActor
@Suite("TerminalKeyBindings", .serialized)
struct TerminalKeyBindingTests {
    let bindings = [
        TerminalKeyBinding(id: "newWindow", input: "t", modifiers: TerminalKeyBinding.command),
        TerminalKeyBinding(id: "selectPane.left", input: TerminalKeyBinding.leftArrow, modifiers: TerminalKeyBinding.command | TerminalKeyBinding.option),
        TerminalKeyBinding(id: "zoomPane", input: "\r", modifiers: TerminalKeyBinding.command | TerminalKeyBinding.shift),
    ]

    private func shuaiCommands(_ view: TerminalView) -> [UIKeyCommand] {
        (view.keyCommands ?? []).filter { $0.propertyList is String }
    }

    @Test func noBindingsNoCommands() {
        let engine = GhosttyEngine()
        #expect(shuaiCommands(engine.view).isEmpty)
    }

    @Test func bindingsAreRegisteredAsPriorityKeyCommandsOnTheTerminalView() throws {
        let engine = GhosttyEngine()
        engine.view.keyBindings = bindings
        let cmds = shuaiCommands(engine.view)
        #expect(cmds.count == 3)
        let t = try #require(cmds.first { $0.propertyList as? String == "newWindow" })
        #expect(t.input == "t")
        #expect(t.modifierFlags == .command)
        #expect(t.wantsPriorityOverSystemBehavior)
        let left = try #require(cmds.first { $0.propertyList as? String == "selectPane.left" })
        #expect(left.input == UIKeyCommand.inputLeftArrow)
        #expect(left.modifierFlags == [.command, .alternate])
        let zoom = try #require(cmds.first { $0.propertyList as? String == "zoomPane" })
        #expect(zoom.modifierFlags == [.command, .shift])
    }

    @Test func triggeringACommandReportsItsId() throws {
        let engine = GhosttyEngine()
        engine.view.keyBindings = bindings
        var got: [String] = []
        engine.view.onKeyBinding = { got.append($0) }
        let cmd = try #require(shuaiCommands(engine.view).first { $0.propertyList as? String == "newWindow" })
        engine.view.performKeyBinding(cmd)
        #expect(got == ["newWindow"])
    }

    @Test func replacingBindingsReplacesCommands() {
        let engine = GhosttyEngine()
        engine.view.keyBindings = bindings
        engine.view.keyBindings = [bindings[0]]
        #expect(shuaiCommands(engine.view).count == 1)
    }

    @Test func commandsAreAvailableWhileTheTerminalIsFirstResponder() {
        let engine = GhosttyEngine()
        engine.view.keyBindings = bindings
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let vc = UIViewController()
        window.rootViewController = vc
        vc.view.addSubview(engine.view)
        engine.view.frame = vc.view.bounds
        window.makeKeyAndVisible()
        #expect(engine.view.canBecomeFirstResponder)
        #expect(shuaiCommands(engine.view).count == 3)
    }
}
#endif
