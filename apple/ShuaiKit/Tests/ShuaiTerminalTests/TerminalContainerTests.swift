#if canImport(GhosttyTerminal) && canImport(UIKit)
import Testing
import UIKit
@testable import ShuaiTerminal

@MainActor
@Suite("TerminalContainer", .serialized)
struct TerminalContainerTests {
    private func mount() -> (GhosttyEngine, TerminalContainerView, UIWindow) {
        let engine = GhosttyEngine()
        let container = TerminalContainerView(terminal: engine.view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let vc = UIViewController()
        window.rootViewController = vc
        vc.view.addSubview(container)
        container.frame = vc.view.bounds
        window.makeKeyAndVisible()
        container.layoutIfNeeded()
        return (engine, container, window)
    }

    @Test func bottomEdgeIsPinnedToTheKeyboardLayoutGuide() {
        let (_, container, _) = mount()
        let pinned = container.constraints.contains {
            ($0.firstItem === container.terminal && $0.firstAttribute == .bottom)
                && ($0.secondItem as? UILayoutGuide) === container.keyboardLayoutGuide
        }
        #expect(pinned, "terminal bottom must follow the keyboard layout guide")
    }

    @Test func withoutKeyboardTheTerminalFillsTheContainer() {
        let (_, container, _) = mount()
        // No software keyboard in tests: the guide falls back to the bottom safe area.
        #expect(container.terminal.frame.maxY <= container.bounds.height + 0.5)
        #expect(container.terminal.frame.height > 700)
    }

    @Test func accessoryBarsTogglePerKeyboardKind() {
        let (_, container, _) = mount()
        container.terminal.showsFloatingAccessoryBar = true
        container.terminal.showsDockedAccessoryBar = false
        #expect(container.terminal.showsFloatingAccessoryBar)
        #expect(container.terminal.inputAccessoryView == nil)
        container.terminal.showsDockedAccessoryBar = true
        #expect(container.terminal.inputAccessoryView === container.terminal.dockedAccessoryBar)
    }
}
#endif
