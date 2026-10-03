#if canImport(GhosttyTerminal) && canImport(UIKit)
import SwiftUI
import UIKit

/// Hosts a `GhosttyEngine`'s terminal view so that its bottom edge sits on the keyboard layout
/// guide: the last terminal row is never covered by the software keyboard or the docked
/// accessory bar (the guide includes the first responder's `inputAccessoryView`). With no
/// keyboard the guide falls back to the bottom safe area.
public final class TerminalContainerView: UIView {
    public let terminal: TerminalView

    public init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        clipsToBounds = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// SwiftUI host for the terminal that avoids the keyboard through `TerminalContainerView`.
/// Apply `.ignoresSafeArea(.keyboard)` so SwiftUI does not shrink the frame a second time.
public struct TerminalContainerRepresentable: UIViewRepresentable {
    public let engine: GhosttyEngine
    public var autoFocus: Bool
    /// Compact floating bar (hardware keyboard).
    public var showsFloatingAccessoryBar: Bool
    /// Docked bar above the software keyboard.
    public var showsDockedAccessoryBar: Bool

    public init(
        engine: GhosttyEngine, autoFocus: Bool = true, showsFloatingAccessoryBar: Bool = false,
        showsDockedAccessoryBar: Bool = true
    ) {
        self.engine = engine
        self.autoFocus = autoFocus
        self.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        self.showsDockedAccessoryBar = showsDockedAccessoryBar
    }

    public func makeUIView(context _: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminal: engine.view)
        apply(to: engine.view)
        return container
    }

    public func updateUIView(_ container: TerminalContainerView, context _: Context) {
        apply(to: container.terminal)
    }

    private func apply(to view: TerminalView) {
        view.autoFocus = autoFocus
        if view.showsFloatingAccessoryBar != showsFloatingAccessoryBar {
            view.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        }
        if view.showsDockedAccessoryBar != showsDockedAccessoryBar {
            view.showsDockedAccessoryBar = showsDockedAccessoryBar
        }
    }
}
#endif
