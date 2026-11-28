#if canImport(GhosttyTerminal) && canImport(UIKit)
import SwiftUI
import UIKit

/// Hosts a `GhosttyEngine`'s terminal view so that its bottom edge sits on the keyboard layout
/// guide: the last terminal row is never covered by the software keyboard or the docked
/// accessory bar (the guide includes the first responder's `inputAccessoryView`). With no
/// keyboard the guide falls back to the bottom safe area.
public final class TerminalContainerView: UIView, UIGestureRecognizerDelegate {
    public let terminal: TerminalView
    var onHistoryScroll: ((Int) -> Void)?
    private var scrollRemainder: CGFloat = 0

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
        installHistoryGestures()
    }

    // In tmux with mouse mode off, the outer terminal is in the alternate buffer
    // and a regular Ghostty scroll can emit cursor keys. Route these gestures to
    // tmux copy mode instead. Let Ghostty handle plain-shell scrollback and apps
    // that explicitly request mouse events.
    private func installHistoryGestures() {
        let touch = UIPanGestureRecognizer(target: self, action: #selector(scrollHistory(_:)))
        touch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touch.maximumNumberOfTouches = 1
        let wheel = HistoryWheelGesture(target: self, action: #selector(scrollHistory(_:)))
        wheel.allowedScrollTypesMask = [.continuous, .discrete]
        for gesture in [touch, wheel] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        for pan in terminal.gestureRecognizers?.compactMap({ $0 as? UIPanGestureRecognizer }) ?? [] {
            pan.require(toFail: pan.allowedScrollTypesMask.isEmpty ? touch : wheel)
        }
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard onHistoryScroll != nil, !terminal.isMouseCaptured,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let translation = pan.translation(in: self)
        return abs(translation.y) >= abs(translation.x)
    }

    @objc private func scrollHistory(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let delta = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            scrollRemainder += delta
            let lines = Int(scrollRemainder / 20)
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines) * 20
            onHistoryScroll?(lines)
        default:
            scrollRemainder = 0
        }
    }

    private final class HistoryWheelGesture: UIPanGestureRecognizer {
        override func shouldReceive(_ event: UIEvent) -> Bool { event.type == .scroll }
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
            let height = bar.heightAnchor.constraint(equalToConstant: bar.intrinsicContentSize.height)
            (bar as? KeyboardAccessoryBar)?.heightConstraint = height
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: centerXAnchor),
                bar.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -8),
                height,
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
    public var hasHardwareKeyboard: Bool
    public var onHistoryScroll: ((Int) -> Void)?

    public init(
        engine: GhosttyEngine, autoFocus: Bool = true, showsFloatingAccessoryBar: Bool = false,
        showsDockedAccessoryBar: Bool = true, hasHardwareKeyboard: Bool = false,
        onHistoryScroll: ((Int) -> Void)? = nil
    ) {
        self.engine = engine
        self.autoFocus = autoFocus
        self.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        self.showsDockedAccessoryBar = showsDockedAccessoryBar
        self.hasHardwareKeyboard = hasHardwareKeyboard
        self.onHistoryScroll = onHistoryScroll
    }

    public func makeUIView(context _: Context) -> TerminalContainerView {
        let container = TerminalContainerView(terminal: engine.view)
        apply(to: container)
        return container
    }

    public func updateUIView(_ container: TerminalContainerView, context _: Context) {
        apply(to: container)
    }

    private func apply(to container: TerminalContainerView) {
        container.onHistoryScroll = onHistoryScroll
        let view = container.terminal
        view.hasHardwareKeyboard = hasHardwareKeyboard
        view.autoFocus = autoFocus
        if view.showsFloatingAccessoryBar != showsFloatingAccessoryBar {
            view.showsFloatingAccessoryBar = showsFloatingAccessoryBar
        }
        view.showsDockedAccessoryBar = showsDockedAccessoryBar
    }
}
#endif
