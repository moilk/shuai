#if canImport(GhosttyTerminal) && canImport(UIKit)
import GhosttyTerminal
import UIKit

/// The terminal UIView. Rendering, UITextInput/IME (inline preedit at the cursor), hardware keys
/// (Ghostty key encoder), pinch/⌘± zoom, selection, scrollback and pointer/mouse reporting come from
/// libghostty's `UITerminalView`; this subclass adds the shuai keyboard accessory bar, a floating
/// compact bar, sticky-modifier mirroring and focus management.
@MainActor
public final class TerminalView: UITerminalView {
    /// Receives strokes produced by the accessory bar (the engine encodes + sends them).
    public var keySink: ((KeyStroke) -> Void)?
    /// Take first responder as soon as the view is in a window.
    public var autoFocus = false
    /// Hardware Option+<char> sends ESC-prefixed Meta (see `OptionAsAlt`). Set by the engine.
    public var altSendsEscape = true

    /// Presses already delivered as Alt chords; their release/cancel must not reach libghostty.
    private var optionChordPresses = Set<UIPress>()

    public lazy var dockedAccessoryBar: KeyboardAccessoryBar = makeBar(.docked)
    public lazy var floatingAccessoryBar: KeyboardAccessoryBar = makeBar(.compactFloating)

    /// Show the docked bar over the software keyboard (default on).
    public var showsDockedAccessoryBar = true {
        // Idempotent: reloading input views re-lays-out the keyboard, so only do it on a real change.
        didSet { if oldValue != showsDockedAccessoryBar { reloadInputViews() } }
    }

    private var mirroringSticky = false
    private var floatingBarInstalled = false

    /// Compact floating bar for hardware-keyboard use.
    public var showsFloatingAccessoryBar: Bool {
        get { floatingBarInstalled && !floatingAccessoryBar.isHidden }
        set { setFloatingBar(visible: newValue) }
    }

    override public var inputAccessoryView: UIView? {
        showsDockedAccessoryBar ? dockedAccessoryBar : nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, autoFocus {
            DispatchQueue.main.async { [weak self] in _ = self?.acquireProgrammaticFocus() }
        }
    }

    // MARK: - App shortcuts

    /// Shortcuts delivered as priority key commands while this view is first responder (the app's
    /// tmux window shortcuts). Replaced wholesale.
    public var keyBindings: [TerminalKeyBinding] = []

    /// Called with the binding's id when one of `keyBindings` fires.
    public var onKeyBinding: ((String) -> Void)?

    override public var keyCommands: [UIKeyCommand]? {
        let own = keyBindings.map { b -> UIKeyCommand in
            let c = UIKeyCommand(
                title: "", action: #selector(performKeyBinding(_:)), input: b.input,
                modifierFlags: UIKeyModifierFlags(rawValue: b.modifiers), propertyList: b.id)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return (super.keyCommands ?? []) + own
    }

    @objc public func performKeyBinding(_ command: UIKeyCommand) {
        guard let id = command.propertyList as? String else { return }
        onKeyBinding?(id)
    }

    // MARK: - Hardware Option as Alt

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard altSendsEscape else { return super.pressesBegan(presses, with: event) }
        var rest = presses
        for press in presses {
            guard let key = press.key, let stroke = Self.optionStroke(for: key) else { continue }
            if markedTextRange != nil { unmarkText() }
            optionChordPresses.insert(press)
            rest.remove(press)
            keySink?(stroke)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(optionChordPresses)
        optionChordPresses.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(optionChordPresses)
        optionChordPresses.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    private static func optionStroke(for key: UIKey) -> KeyStroke? {
        let f = key.modifierFlags
        return OptionAsAlt.stroke(
            base: key.charactersIgnoringModifiers,
            shift: f.contains(.shift), control: f.contains(.control),
            command: f.contains(.command), option: f.contains(.alternate)
        )
    }

    // MARK: - Bars

    private func makeBar(_ style: KeyboardAccessoryBar.Style) -> KeyboardAccessoryBar {
        let bar = KeyboardAccessoryBar(style: style)
        bar.onKey = { [weak self] stroke in self?.deliver(stroke) }
        bar.onModifiersChanged = { [weak self] model in self?.mirrorSticky(model) }
        setStickyModifierChangeHandler { [weak self] in self?.libStickyChanged() }
        return bar
    }

    private func deliver(_ stroke: KeyStroke) {
        // A key from the bar closes any open composition first (like a hardware chord).
        if markedTextRange != nil { unmarkText() }
        keySink?(stroke)
    }

    private func setFloatingBar(visible: Bool) {
        let bar = floatingAccessoryBar
        if let container = superview as? TerminalContainerView {
            // Hosted next to the terminal, not inside it (see `TerminalContainerView.setFloatingBar`).
            floatingBarInstalled = true
            container.setFloatingBar(bar, visible: visible)
            return
        }
        if !floatingBarInstalled {
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.centerXAnchor.constraint(equalTo: centerXAnchor),
                bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
                bar.heightAnchor.constraint(equalToConstant: 44),
                bar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
                bar.widthAnchor.constraint(equalToConstant: 780).withPriority(.defaultHigh),
            ])
            floatingBarInstalled = true
        }
        bar.isHidden = !visible
    }

    // MARK: - Sticky modifier mirroring

    /// Typed software-keyboard text consults libghostty's own sticky state, so keep it identical to the
    /// bar's model: bar -> lib on bar taps, lib -> bar when a typed key spent a one-shot.
    private func mirrorSticky(_ model: AccessoryBarModel) {
        mirroringSticky = true
        defer { mirroringSticky = false }
        resetStickyModifiers()
        for (modifier, state) in [(TerminalPublicStickyModifier.ctrl, model.ctrl), (.alt, model.alt)] {
            switch state {
            case .off: break
            case .oneShot: toggleStickyModifier(modifier)
            case .locked:
                toggleStickyModifier(modifier)
                toggleStickyModifier(modifier) // inside the double-tap window -> locked
            }
        }
        for bar in [dockedAccessoryBar, floatingAccessoryBar] where bar.model != model {
            bar.syncModifiers(ctrl: model.ctrl, alt: model.alt)
        }
    }

    private func libStickyChanged() {
        guard !mirroringSticky else { return }
        let ctrl = Self.sticky(stickyActivation(for: .ctrl))
        let alt = Self.sticky(stickyActivation(for: .alt))
        dockedAccessoryBar.syncModifiers(ctrl: ctrl, alt: alt)
        floatingAccessoryBar.syncModifiers(ctrl: ctrl, alt: alt)
    }

    private static func sticky(_ a: TerminalPublicStickyActivation) -> StickyState {
        switch a {
        case .inactive: .off
        case .armed: .oneShot
        case .locked: .locked
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
#endif
