#if canImport(UIKit)
import UIKit

/// Accessory bar over the software keyboard (docked) or a compact floating variant for hardware
/// keyboards. All state and key mapping live in `AccessoryBarModel`; this class is only presentation.
@MainActor
public final class KeyboardAccessoryBar: UIView {
    public enum Style {
        /// Two rows (Claude strip + standard keys), used as `inputAccessoryView`.
        case docked
        /// One scrolling row, rounded translucent capsule floating over the terminal.
        case compactFloating
    }

    public let style: Style
    public private(set) var model = AccessoryBarModel()

    /// A stroke to deliver to the terminal (modifiers already applied).
    public var onKey: ((KeyStroke) -> Void)?
    /// Sticky Ctrl/Alt changed (so the terminal view can mirror them for typed text).
    public var onModifiersChanged: ((AccessoryBarModel) -> Void)?

    private var buttons: [AccessoryButton: UIButton] = [:]
    private var repeatTimer: Timer?
    private var repeatDelayTask: Task<Void, Never>?

    public static let repeatDelay: Duration = .milliseconds(400)
    public static let repeatInterval: TimeInterval = 0.07

    public init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        frame = CGRect(x: 0, y: 0, width: 600, height: barHeight)
        autoresizingMask = style == .docked ? [.flexibleWidth] : []
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: KeyboardAccessoryBar, _) in
            // One turn later: the rest of the UI (SwiftUI) lays itself out for the new text size
            // first, so rebuilding the bar and reloading the input views does not delay it.
            DispatchQueue.main.async { [weak bar] in bar?.contentSizeChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    // MARK: - Dynamic Type

    /// Called after a text size change so the host can re-run input view layout.
    public var onBarHeightChanged: (() -> Void)?
    /// Height constraint installed by a host that pins the bar (floating bar); kept in sync.
    public weak var heightConstraint: NSLayoutConstraint?

    private var scaledFont: UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: CGFloat(AccessoryBarMetrics.baseFontSize), weight: .medium)
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: base, maximumPointSize: CGFloat(AccessoryBarMetrics.maxFontSize), compatibleWith: traitCollection)
    }

    private var rowHeight: Double {
        AccessoryBarMetrics.rowHeight(
            lineHeight: Double(scaledFont.lineHeight),
            scale: Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traitCollection)))
    }

    /// Bar height for the current text size.
    var barHeight: CGFloat {
        CGFloat(style == .docked
            ? AccessoryBarMetrics.dockedHeight(rowHeight: rowHeight)
            : AccessoryBarMetrics.floatingHeight(rowHeight: rowHeight))
    }

    /// Minimum key width: scales with the text, never below the 40 pt it had before.
    private var minKeyWidth: CGFloat {
        max(40, CGFloat(AccessoryBarMetrics.minRowHeight) * scaledFont.pointSize
            / CGFloat(AccessoryBarMetrics.baseFontSize))
    }

    private func fontTransformer() -> UIConfigurationTextAttributesTransformer {
        UIConfigurationTextAttributesTransformer { [weak self] attributes in
            var attributes = attributes
            attributes.font = self?.scaledFont
                ?? UIFont.monospacedSystemFont(ofSize: CGFloat(AccessoryBarMetrics.baseFontSize), weight: .medium)
            return attributes
        }
    }

    private func contentSizeChanged() {
        for button in buttons.values {
            var config = button.configuration ?? .gray()
            config.titleTextAttributesTransformer = fontTransformer()
            button.configuration = config
            for constraint in button.constraints where constraint.firstAttribute == .width && constraint.relation == .greaterThanOrEqual {
                constraint.constant = minKeyWidth
            }
        }
        refreshModifierButtons()
        heightConstraint?.constant = barHeight
        invalidateIntrinsicContentSize()
        frame.size.height = barHeight
        setNeedsLayout()
        onBarHeightChanged?()
    }

    /// Adopt sticky state held by the terminal view (a typed key spent a one-shot).
    public func syncModifiers(ctrl: StickyState, alt: StickyState) {
        model.sync(ctrl: ctrl, alt: alt)
        refreshModifierButtons()
    }

    /// Simulates a tap (also used by tests/automation).
    public func tap(_ button: AccessoryButton) {
        let before = model
        for stroke in model.press(button) { onKey?(stroke) }
        refreshModifierButtons()
        if before.ctrl != model.ctrl || before.alt != model.alt { onModifiersChanged?(model) }
    }

    // MARK: - Build

    private func build() {
        backgroundColor = style == .docked ? .secondarySystemBackground : .clear
        switch style {
        case .docked:
            let top = row(AccessoryButton.claudeStrip, tint: .systemPurple)
            let bottom = row(AccessoryButton.standardRow, tint: nil)
            let stack = UIStackView(arrangedSubviews: [top, bottom])
            stack.axis = .vertical
            stack.distribution = .fillEqually
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        case .compactFloating:
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            blur.layer.cornerRadius = 22
            blur.clipsToBounds = true
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            let compact: [AccessoryButton] = [.esc, .ctrl, .alt, .tab, .up, .down, .left, .right] + AccessoryButton.claudeStrip
            let r = row(compact, tint: nil)
            r.translatesAutoresizingMaskIntoConstraints = false
            blur.contentView.addSubview(r)
            NSLayoutConstraint.activate([
                blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                blur.topAnchor.constraint(equalTo: topAnchor),
                blur.bottomAnchor.constraint(equalTo: bottomAnchor),
                r.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 8),
                r.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -8),
                r.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 4),
                r.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -4),
            ])
        }
        refreshModifierButtons()
    }

    private func row(_ items: [AccessoryButton], tint: UIColor?) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillProportionally
        for item in items {
            let b = makeButton(item, tint: tint)
            // Claude strip buttons are duplicated in compact mode only once, so the last wins.
            buttons[item] = b
            stack.addArrangedSubview(b)
        }
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            // Fill the row when it fits; scroll when it doesn't.
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        return scroll
    }

    private func makeButton(_ item: AccessoryButton, tint: UIColor?) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = item.title
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let tint { config.baseForegroundColor = tint }
        config.titleTextAttributesTransformer = fontTransformer()
        let button = UIButton(configuration: config)
        button.accessibilityLabel = item.spokenLabel
        button.accessibilityIdentifier = item.accessibilityIdentifier
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minKeyWidth).isActive = true
        if AccessoryBarModel.isRepeatable(item) {
            button.addAction(UIAction { [weak self] _ in self?.beginRepeat(item) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.endRepeat() },
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        } else {
            button.addAction(UIAction { [weak self] _ in self?.tap(item) }, for: .touchUpInside)
        }
        return button
    }

    // MARK: - Repeat

    private func beginRepeat(_ item: AccessoryButton) {
        tap(item)
        endRepeat()
        repeatDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.repeatDelay)
            guard !Task.isCancelled, let self else { return }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tap(item) }
            }
        }
    }

    private func endRepeat() {
        repeatDelayTask?.cancel()
        repeatDelayTask = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Modifier appearance

    private func refreshModifierButtons() {
        for (item, state) in [(AccessoryButton.ctrl, model.ctrl), (.alt, model.alt)] {
            guard let button = buttons[item] else { continue }
            var config = button.configuration ?? .gray()
            switch state {
            case .off:
                config = UIButton.Configuration.gray()
                config.title = item.title
            case .oneShot:
                config = UIButton.Configuration.filled()
                config.baseBackgroundColor = .systemBlue
                // Not colour alone: a border marks the armed state.
                config.background.strokeColor = .label
                config.background.strokeWidth = 2
                config.title = item.title
            case .locked:
                config = UIButton.Configuration.filled()
                config.baseBackgroundColor = .systemOrange
                config.title = item.title + " 🔒"
            }
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.titleTextAttributesTransformer = fontTransformer()
            button.configuration = config
            button.accessibilityValue = state.accessibilityValue
            if state == .off {
                button.accessibilityTraits.remove(.selected)
            } else {
                button.accessibilityTraits.insert(.selected)
            }
        }
    }
}
#endif
