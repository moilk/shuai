import Foundation

/// OSC 9 / OSC 777 desktop notification raised by the remote program.
public struct TerminalNotification: Sendable, Equatable {
    public var title: String
    public var body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum ClipboardRequestKind: Sendable, Equatable {
    /// Unsafe paste needing confirmation.
    case paste
    /// Remote asked to read the local clipboard (OSC 52 `?`).
    case osc52Read
    /// Remote wants to write the local clipboard (OSC 52).
    case osc52Write
}

/// A one-shot clipboard decision the app must answer (show UI, then `respond(allow:)`).
/// Dropping the request without answering denies it.
@MainActor
public final class ClipboardRequest {
    public let contents: String
    public let kind: ClipboardRequestKind
    private var completion: ((Bool) -> Void)?

    public init(contents: String, kind: ClipboardRequestKind, completion: @escaping (Bool) -> Void) {
        self.contents = contents
        self.kind = kind
        self.completion = completion
    }

    public func respond(allow: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(allow)
    }

    deinit {
        MainActor.assumeIsolated { completion?(false) }
    }
}

/// Terminal emulator + renderer abstraction. `GhosttyEngine` (libghostty) is the shipping engine; the
/// protocol exists so another engine (e.g. SwiftTerm) could be swapped in without touching the app.
///
/// All bytes that must go to the remote — typed input, pastes and the engine's own replies to
/// terminal queries (DA1, DECRQM, kitty `CSI ? u`, ...) — are delivered through `onInput`.
@MainActor
public protocol TerminalEngine: AnyObject {
    /// Bytes from the remote (SSH channel / tmux). Parsing is asynchronous.
    func feed(_ data: Data)
    /// Request a fixed grid (replay tools, tests). Normally the view's size drives the grid.
    func resize(cols: Int, rows: Int)
    var gridSize: TerminalGridSize { get }
    var title: String { get }

    /// Send a key through the engine's encoder (kitty protocol aware when the remote enabled it).
    func sendKey(_ stroke: KeyStroke)
    /// Paste text; bracketed when the remote enabled mode 2004.
    func paste(_ text: String)
    /// Whether the remote application captures the mouse (modes 1000/1002/1003).
    var isMouseReportingEnabled: Bool { get }
    /// Visible screen text (row per line); for tests and accessibility.
    func readScreenText() -> String?

    /// Bytes to write to the remote.
    var onInput: ((Data) -> Void)? { get set }
    /// Grid size changed (debounced). Send SSH window-change from here.
    var onResize: ((TerminalGridSize) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
    var onBell: (() -> Void)? { get set }
    var onNotification: ((TerminalNotification) -> Void)? { get set }
    /// OSC 52 write/read and unsafe paste. The app MUST confirm; unanswered/absent handler = deny.
    var onClipboardRequest: ((ClipboardRequest) -> Void)? { get set }
    /// User activated a hyperlink (OSC 8 or detected URL).
    var onHyperlink: ((URL) -> Void)? { get set }
}
