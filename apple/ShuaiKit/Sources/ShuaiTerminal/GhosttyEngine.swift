#if canImport(GhosttyTerminal) && canImport(UIKit)
import Foundation
import GhosttyTerminal
import UIKit

/// `TerminalEngine` backed by libghostty (Lakr233/libghostty-spm, pinned). Bytes come from an external
/// source (SSH channel) via `feed`; nothing is spawned locally.
@MainActor
public final class GhosttyEngine: NSObject, TerminalEngine {
    public let view: TerminalView

    public var onInput: ((Data) -> Void)?
    public var onResize: ((TerminalGridSize) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onNotification: ((TerminalNotification) -> Void)?
    public var onClipboardRequest: ((ClipboardRequest) -> Void)?
    public var onHyperlink: ((URL) -> Void)?

    public private(set) var gridSize = TerminalGridSize(cols: 0, rows: 0)
    public private(set) var title = ""

    /// Alt/Option sends ESC-prefixed Meta sequences (used by the non-Ghostty fallback path and the
    /// Ghostty config).
    public let altSendsEscape: Bool

    /// Active theme. The terminal ignores the system light/dark appearance.
    public private(set) var theme: TerminalTheme

    private let session: InMemoryTerminalSession
    let controller: TerminalController
    private var debouncer: ResizeDebouncer!
    private var metrics: TerminalGridMetrics?
    private var fixedGrid: TerminalGridSize?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    private final class InputBox: @unchecked Sendable { var handler: ((Data) -> Void)? }

    public init(
        fontSize: Float = 12,
        resizeDebounce: TimeInterval = 0.15,
        altSendsEscape: Bool = true,
        theme: TerminalTheme = .default,
        scrollbackLines: Int = ScrollbackPolicy.defaultLines
    ) {
        let box = InputBox()
        self.altSendsEscape = altSendsEscape
        self.theme = theme
        session = InMemoryTerminalSession(
            write: { data in
                #if DEBUG
                if let delay = Self.debugReplyDelay(for: data) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { box.handler?(data) }
                    return
                }
                #endif
                DispatchQueue.main.async { box.handler?(data) }
            },
            resize: { _ in }
        )
        controller = TerminalController(theme: theme.ghostty) { b in
            b.withFontSize(fontSize)
            b.withWindowPaddingX(0)
            b.withWindowPaddingY(0)
            // Remote OSC 52 clipboard writes must be confirmed by the app, never silent.
            b.withCustom("clipboard-write", "ask")
            b.withCustom("clipboard-read", "ask")
            // Kept for Ghostty's own encoder; TerminalView also maps hardware Option chords (OptionAsAlt)
            // because the iOS embedding is not known to honour this key.
            b.withCustom("macos-option-as-alt", altSendsEscape ? "true" : "false")
            // Bounded history: Ghostty's limit is in bytes per surface.
            b.withCustom("scrollback-limit", String(ScrollbackPolicy.limitBytes(lines: scrollbackLines)))
        }
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        view.altSendsEscape = altSendsEscape
        view.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        view.dockedAccessoryBar.apply(theme: theme)
        view.floatingAccessoryBar.apply(theme: theme)
        super.init()
        debouncer = ResizeDebouncer(delay: resizeDebounce) { [weak self] in self?.onResize?($0) }
        box.handler = { [weak self] data in self?.onInput?(data) }
        view.keySink = { [weak self] in self?.sendKey($0) }
        view.delegate = self
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
    }

    #if DEBUG
    /// DEBUG-only (`-debugDelayReplies <seconds>`): holds back DA1/DA2/XTVERSION replies to reproduce a late engine.
    nonisolated private static func debugReplyDelay(for data: Data) -> TimeInterval? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-debugDelayReplies"), i + 1 < args.count, let sec = TimeInterval(args[i + 1]),
              data.count > 2, data[data.startIndex] == 0x1B else { return nil }
        let b1 = data[data.startIndex + 1], b2 = data[data.startIndex + 2]
        let isDA = b1 == 0x5B && (b2 == 0x3F || b2 == 0x3E) && data.last == 0x63
        return isDA || b1 == 0x50 ? sec : nil
    }
    #endif

    // MARK: TerminalEngine

    public func feed(_ data: Data) { session.receive(data) }

    /// Switches theme live (both Ghostty light/dark variants, so system appearance never matters).
    public func apply(theme: TerminalTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        view.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        view.dockedAccessoryBar.apply(theme: theme)
        view.floatingAccessoryBar.apply(theme: theme)
        controller.setTheme(theme.ghostty)
    }

    public func resize(cols: Int, rows: Int) {
        // A 0x0 grid is never valid (division by zero in reflow, zero-size PTY).
        fixedGrid = TerminalGridSize(cols: max(cols, 1), rows: max(rows, 1))
        if widthConstraint == nil {
            view.translatesAutoresizingMaskIntoConstraints = false
            widthConstraint = view.widthAnchor.constraint(equalToConstant: 900)
            heightConstraint = view.heightAnchor.constraint(equalToConstant: 700)
            NSLayoutConstraint.activate([widthConstraint!, heightConstraint!])
        }
        applyFixedGrid()
    }

    public func sendKey(_ stroke: KeyStroke) {
        if let surface = view.surface, let press = GhosttyKeyMapping.press(for: stroke),
           surface.sendKey(press)
        {
            return
        }
        // No surface yet, or a character with no US-layout key (CJK etc.): plain UTF-8 / xterm bytes.
        if let data = KeyEncoder.encode(stroke, options: KeyEncoderOptions(altSendsEscape: altSendsEscape)) {
            session.sendInput(data)
        }
    }

    public func paste(_ text: String) { _ = view.paste(text: text) }

    public var isMouseReportingEnabled: Bool { view.isMouseCaptured }

    public func readScreenText() -> String? {
        session.readViewportText().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                .joined(separator: "\n")
        }
    }

    /// Waits until fed bytes are parsed and any resulting replies reached `onInput` (tests, replay).
    public func settle() async {
        for _ in 0 ..< 80 {
            if session.waitForPendingOutput() { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// View size in points that yields exactly `cols` x `rows` at the current font (nil until the first
    /// layout reports cell metrics). Use with `.frame` in SwiftUI instead of `resize(cols:rows:)`.
    public func pointSize(cols: Int, rows: Int) -> CGSize? {
        guard let m = metrics, m.cellWidthPixels > 0, m.cellHeightPixels > 0 else { return nil }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        return CGSize(width: (CGFloat(m.cellWidthPixels) * (CGFloat(cols) + 0.25)) / scale,
                      height: (CGFloat(m.cellHeightPixels) * (CGFloat(rows) + 0.25)) / scale)
    }

    // MARK: Fixed-grid mode

    private func applyFixedGrid() {
        guard let g = fixedGrid, let m = metrics, m.cellWidthPixels > 0, m.cellHeightPixels > 0 else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let w = (CGFloat(m.cellWidthPixels) * CGFloat(g.cols) + 0.25 * CGFloat(m.cellWidthPixels)) / scale
        let h = (CGFloat(m.cellHeightPixels) * CGFloat(g.rows) + 0.25 * CGFloat(m.cellHeightPixels)) / scale
        guard let wc = widthConstraint, let hc = heightConstraint else { return }
        if abs(wc.constant - w) > 0.01 || abs(hc.constant - h) > 0.01 {
            wc.constant = w
            hc.constant = h
            view.superview?.setNeedsLayout()
        }
    }
}

// MARK: - libghostty delegates

extension GhosttyEngine:
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceClipboardConfirmationDelegate,
    TerminalSurfaceOpenURLDelegate
{
    public func terminalDidResize(_ size: TerminalGridMetrics) {
        metrics = size
        let grid = TerminalGridSize(cols: Int(size.columns), rows: Int(size.rows))
        // A collapsed view (keyboard animation, zero-size Stage Manager frame) reports 0 cols/rows:
        // keep the last valid grid and never forward it.
        if grid.isValid, grid != gridSize {
            gridSize = grid
            debouncer.submit(grid)
        }
        applyFixedGrid()
    }

    public func terminalDidChangeTitle(_ title: String) {
        self.title = title
        onTitleChange?(title)
    }

    public func terminalDidRingBell() { onBell?() }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        onNotification?(TerminalNotification(title: title, body: body))
    }

    public func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        guard let handler = onClipboardRequest else {
            request.respond(allow: false)
            return
        }
        let kind: ClipboardRequestKind = switch request.kind {
        case .paste: .paste
        case .osc52Read: .osc52Read
        case .osc52Write: .osc52Write
        }
        handler(ClipboardRequest(contents: request.contents, kind: kind) { request.respond(allow: $0) })
    }

    public func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        if let u = URL(string: url) { onHyperlink?(u) }
    }
}
// MARK: - Theme -> Ghostty

extension TerminalTheme {
    /// Ghostty config for this theme.
    var ghosttyConfiguration: TerminalConfiguration {
        TerminalConfiguration { b in
            b.withBackground(background.hexString)
            b.withForeground(foreground.hexString)
            b.withCursorColor(cursor.hexString)
            b.withSelectionBackground(selection.hexString)
            b.withSelectionForeground(foreground.hexString)
            for (i, c) in palette.enumerated() { b.withPalette(i, color: c.hexString) }
        }
    }

    /// Same colors for Ghostty's light and dark variants: the terminal never follows system appearance.
    var ghostty: GhosttyTerminal.TerminalTheme {
        GhosttyTerminal.TerminalTheme(light: ghosttyConfiguration, dark: ghosttyConfiguration)
    }
}
#endif
