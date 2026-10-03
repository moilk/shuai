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
        ])
        terminalBottomToKeyboard = terminal.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        terminalBottomToKeyboard.isActive = true
    }

    private var terminalBottomToKeyboard: NSLayoutConstraint!
    private var terminalBottomToBar: NSLayoutConstraint?
    private weak var hostedBar: UIView?

    /// Hosts the compact floating bar as a sibling of the terminal (the terminal is a scroll view:
    /// a subview of it scrolls away with the content). The bar sits on the keyboard layout guide and
    /// the terminal's bottom moves above it while it is visible, so it never covers text.
    func setFloatingBar(_ bar: UIView, visible: Bool) {
        if hostedBar == nil {
            hostedBar = bar
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            let width = bar.widthAnchor.constraint(equalToConstant: 780)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: centerXAnchor),
                bar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -8),
                bar.heightAnchor.constraint(equalToConstant: 44),
                bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
                width,
            ])
            terminalBottomToBar = terminal.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
        }
        bar.isHidden = !visible
        if visible {
            guard terminalBottomToBar?.isActive != true else { return }
            terminalBottomToKeyboard.isActive = false
            terminalBottomToBar?.isActive = true
        } else {
            guard terminalBottomToKeyboard.isActive == false else { return }
            terminalBottomToBar?.isActive = false
            terminalBottomToKeyboard.isActive = true
        }
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
        view.showsDockedAccessoryBar = showsDockedAccessoryBar
    }
}
#endif
