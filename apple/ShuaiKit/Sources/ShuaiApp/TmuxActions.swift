import Foundation
import Observation
import ShuaiCore

/// What the user can do to tmux from the UI and the keyboard. Every command goes through the
/// monitor's control channel; anything about "what the terminal shows" first moves the PTY
/// client (`switch-client -c TTY`), because the control client's own current session is not the
/// terminal's.
@MainActor @Observable
public final class TmuxActions {
    public struct Confirmation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case killWindow(id: String), killPane(id: String) }
        public var kind: Kind
        public var title: String
        public var message: String
    }

    public private(set) var pendingConfirmation: Confirmation?

    @ObservationIgnored private let monitor: TmuxMonitor
    @ObservationIgnored private let notices: NoticeRoute?
    @ObservationIgnored private var isRetired = false

    /// - Parameter notices: where failed `run { }` actions are reported; nil drops them.
    public init(monitor: TmuxMonitor, notices: NoticeRoute? = nil) {
        self.monitor = monitor
        self.notices = notices
    }

    /// The host is gone: later failures post nothing.
    public func retire() { isRetired = true }

    // MARK: - Derived state

    /// The session the terminal currently shows (the PTY client's), else the monitored session.
    public var viewedSession: FfiTmuxSession? {
        guard let t = monitor.topology else { return nil }
        if let id = monitor.viewedSessionID, let s = t.sessions.first(where: { $0.id == id }) { return s }
        return t.sessions.first { $0.name == monitor.sessionName }
    }

    /// Windows in tmux list order (by index): the position a shortcut like ⌘2 refers to.
    public var windows: [FfiTmuxWindow] { (viewedSession?.windows ?? []).sorted { $0.index < $1.index } }
    public var activeWindow: FfiTmuxWindow? { windows.first(where: \.active) ?? windows.first }
    public var activePane: FfiTmuxPane? { activeWindow.flatMap { $0.panes.first(where: \.active) ?? $0.panes.first } }

    private var sessionName: String { viewedSession?.name ?? monitor.sessionName }

    private func location(ofWindow id: String) -> (session: FfiTmuxSession, window: FfiTmuxWindow)? {
        for s in monitor.topology?.sessions ?? [] { for w in s.windows where w.id == id { return (s, w) } }
        return nil
    }

    private func location(ofPane id: String) -> (session: FfiTmuxSession, window: FfiTmuxWindow, pane: FfiTmuxPane)? {
        for s in monitor.topology?.sessions ?? [] {
            for w in s.windows { for p in w.panes where p.id == id { return (s, w, p) } }
        }
        return nil
    }

    // MARK: - Selecting

    public func selectWindow(_ id: String) async throws {
        if let loc = location(ofWindow: id) { try await ensureViewing(loc.session.id) }
        try await monitor.run(tmuxSelectWindow(windowId: id))
    }

    /// 1-based position in the window list (not the tmux index, so `base-index` does not matter).
    /// Out of range positions are ignored.
    public func selectWindow(position: Int) async throws {
        let w = windows
        guard w.indices.contains(position - 1) else { return }
        try await selectWindow(w[position - 1].id)
    }

    public func selectPane(_ id: String) async throws {
        if let loc = location(ofPane: id) {
            try await ensureViewing(loc.session.id)
            try await monitor.run(tmuxSelectWindow(windowId: loc.window.id))
        }
        try await monitor.run(tmuxSelectPane(paneId: id))
    }

    public func selectPane(direction: PaneDirection) async throws {
        guard let w = activeWindow else { return }
        let d: FfiPaneDirection = switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        try await monitor.run(tmuxSelectPaneDirection(windowId: w.id, direction: d))
    }

    /// Moves the terminal to `sessionID` (`$1`).
    public func switchSession(_ sessionID: String) async throws {
        guard let tty = monitor.ptyClientTty else { throw TmuxError.noPtyClient }
        try await monitor.run(tmuxSwitchClient(clientTty: tty, sessionId: sessionID))
    }

    private func ensureViewing(_ sessionID: String) async throws {
        guard monitor.viewedSessionID != nil, monitor.viewedSessionID != sessionID else { return }
        try await switchSession(sessionID)
    }

    // MARK: - Structure

    /// A new window in the viewed session, starting in the active pane's directory.
    public func newWindow() async throws {
        let cwd = activePane.map(\.currentPath).flatMap { $0.isEmpty ? nil : $0 }
        try await monitor.run(tmuxNewWindow(session: sessionName, cwd: cwd, name: nil))
    }

    public func renameWindow(_ id: String, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await monitor.run(tmuxRenameWindow(windowId: id, name: trimmed))
    }

    /// Splits the active pane; `horizontal` puts the panes side by side.
    public func split(horizontal: Bool) async throws {
        guard let p = activePane else { return }
        try await split(pane: p.id, horizontal: horizontal)
    }

    public func split(pane id: String, horizontal: Bool) async throws {
        let cwd = location(ofPane: id)?.pane.currentPath
        try await monitor.run(tmuxSplitWindow(paneId: id, horizontal: horizontal, cwd: cwd.flatMap { $0.isEmpty ? nil : $0 }))
    }

    public func nextWindow() async throws { try await monitor.run(tmuxNextWindow(session: sessionName)) }
    public func previousWindow() async throws { try await monitor.run(tmuxPreviousWindow(session: sessionName)) }
    public func lastWindow() async throws { try await monitor.run(tmuxLastWindow(session: sessionName)) }

    public func zoom() async throws {
        guard let p = activePane else { return }
        try await monitor.run(tmuxZoomPane(paneId: p.id))
    }

    // MARK: - Kill (confirmed)

    public func requestKillWindow(_ id: String) {
        guard let loc = location(ofWindow: id) else { return }
        let n = loc.window.panes.count
        pendingConfirmation = Confirmation(
            kind: .killWindow(id: id), title: "Close window \u{201C}\(loc.window.name)\u{201D}?",
            message: n > 1 ? "Its \(n) panes and their running programs are closed." : "The running program in it is closed.")
    }

    public func requestKillPane(_ id: String) {
        guard let loc = location(ofPane: id) else { return }
        let only = loc.window.panes.count == 1
        pendingConfirmation = Confirmation(
            kind: .killPane(id: id), title: "Close pane \u{201C}\(loc.pane.currentCommand)\u{201D}?",
            message: only
                ? "It is the only pane of its window, so the window closes too. The running program is closed."
                : "The running program in it is closed.")
    }

    public func confirmPending() async throws {
        guard let c = pendingConfirmation else { return }
        try await confirm(c)
    }

    /// Runs a confirmation the caller captured. A dialog's dismissal clears `pendingConfirmation`
    /// in the same turn as its button action, so the button captures the value synchronously.
    public func confirm(_ c: Confirmation) async throws {
        if pendingConfirmation == c { pendingConfirmation = nil }
        switch c.kind {
        case .killWindow(let id): try await monitor.run(tmuxKillWindow(windowId: id))
        case .killPane(let id): try await monitor.run(tmuxKillPane(paneId: id))
        }
    }

    public func cancelPending() { pendingConfirmation = nil }

    // MARK: - Quick switcher

    /// Jumps to a switcher result of this host (the caller selects the host first).
    public func jump(to item: SwitcherItem) async throws {
        switch item.kind {
        case .pane:
            if let p = item.paneID { try await selectPane(p) }
        case .window:
            if let w = item.windowID { try await selectWindow(w) }
        case .session:
            if let s = item.sessionID, s != monitor.viewedSessionID { try await switchSession(s) }
        case .host:
            break
        }
    }

    // MARK: - Shortcuts

    /// Runs a keyboard shortcut's action. `.quickSwitcher` and `.nextAttention` are UI-only and ignored here.
    public func perform(_ action: ShortcutAction) async throws {
        switch action {
        case .selectWindow(let n): try await selectWindow(position: n)
        case .newWindow: try await newWindow()
        case .killWindow: if let w = activeWindow { requestKillWindow(w.id) }
        case .previousWindow: try await previousWindow()
        case .nextWindow: try await nextWindow()
        case .lastWindow: try await lastWindow()
        case .splitRight: try await split(horizontal: true)
        case .splitDown: try await split(horizontal: false)
        case .selectPane(let d): try await selectPane(direction: d)
        case .zoomPane: try await zoom()
        case .quickSwitcher, .nextAttention: break
        }
    }

    /// Fire-and-forget wrapper for UI callbacks: failures are posted as an error notice.
    public func run(_ body: @MainActor () async throws -> Void) async {
        do { try await body() } catch { postError(Self.describe(error)) }
    }

    private func postError(_ text: String) {
        guard !isRetired, let route = notices else { return }
        route.poster.post(Notice(
            severity: .error, source: .tmux, scope: .host(route.hostID), text: Notice.collapseHomePaths(text),
            symbol: "exclamationmark.octagon", key: Self.errorKey(hostID: route.hostID)))
    }

    static func errorKey(hostID: UUID) -> String { "tmux-error:\(hostID.uuidString)" }

    static func describe(_ error: Error) -> String {
        switch error as? TmuxError {
        case .notRunning: "tmux is not connected."
        case .channelClosed: "The tmux channel closed."
        case .commandFailed(let m): m.isEmpty ? "tmux command failed." : m
        case .noPtyClient: "Could not find this terminal's tmux client."
        case .invalidTarget(let t): "Invalid tmux target \(t)."
        case nil: String(describing: error)
        }
    }
}

/// Where one host's notices go: the poster plus the host that scopes and keys them.
public struct NoticeRoute {
    public let hostID: UUID
    public let poster: any NoticePosting

    public init(hostID: UUID, poster: any NoticePosting) {
        self.hostID = hostID
        self.poster = poster
    }
}
