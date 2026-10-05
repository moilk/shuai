import Foundation

extension SessionState.Status {
    /// SF Symbol with a distinct shape per status, so state never relies on colour alone.
    public var symbol: String {
        switch self {
        case .off: "circle.dashed"
        case .busy: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .warning: "arrow.triangle.2.circlepath"
        case .error: "xmark.octagon.fill"
        }
    }

    public var label: String {
        switch self {
        case .off: "Not connected"
        case .busy: "Connecting"
        case .connected: "Connected"
        case .warning: "Reconnecting"
        case .error: "Connection failed"
        }
    }
}

/// What the UI shows for a session's connection state. Only states without a usable live channel
/// block the terminal; reconnecting and disconnected keep the last output readable.
public struct ConnectionPresentation: Equatable, Sendable {
    public enum Placement: Sendable { case none, strip, card }

    public enum Action: Equatable, Sendable {
        case retryNow, cancelReconnect, cancelConnect, retry, reconnect, editHost, openKeys

        public var title: String {
            switch self {
            case .retryNow: "Retry now"
            case .cancelReconnect, .cancelConnect: "Cancel"
            case .retry: "Retry"
            case .reconnect: "Reconnect"
            case .editHost: "Edit host"
            case .openKeys: "Open keys"
            }
        }

        public var accessibilityIdentifier: String {
            switch self {
            case .retryNow: "retry-now"
            case .cancelReconnect: "cancel-reconnect"
            case .cancelConnect: "cancel-connect"
            case .retry: "retry-connect"
            case .reconnect: "reconnect-session"
            case .editHost: "edit-host"
            case .openKeys: "open-keys"
            }
        }
    }

    public var placement: Placement
    public var dimsTerminal: Bool
    public var showsProgress: Bool
    public var symbol: String
    public var tone: SessionState.Status
    public var title: String
    public var detail: String?
    public var retryAt: Date?
    public var attempt: Int?
    public var actions: [Action]
    public var accessibilityIdentifier: String
    public var accessibilityLabel: String

    public static func make(_ s: SessionState, hostName: String, target: String) -> Self {
        let status = s.status
        var p = ConnectionPresentation(
            placement: .none, dimsTerminal: false, showsProgress: false,
            symbol: status.symbol, tone: status, title: "", detail: nil,
            retryAt: nil, attempt: nil, actions: [], accessibilityIdentifier: "",
            accessibilityLabel: "\(hostName): \(status.label)")
        switch s {
        case .idle, .connected:
            break
        case .connecting:
            p.placement = .card
            p.showsProgress = true
            p.title = "Connecting to \(hostName)…"
            p.detail = target
            p.actions = [.cancelConnect]
            p.accessibilityIdentifier = "connecting-card"
        case .authenticating:
            p.placement = .card
            p.showsProgress = true
            p.title = "Signing in to \(hostName)…"
            p.detail = target
            p.actions = [.cancelConnect]
            p.accessibilityIdentifier = "connecting-card"
        case .hostKeyPrompt:
            p.placement = .card
            p.title = "Verify \(hostName)'s host key"
            p.accessibilityIdentifier = "connecting-card"
        case .reconnecting(let attempt, let nextRetryAt):
            p.placement = .strip
            p.showsProgress = true
            p.title = "Reconnecting to \(hostName)"
            p.attempt = attempt
            p.retryAt = nextRetryAt
            p.actions = [.retryNow, .cancelReconnect]
            p.accessibilityIdentifier = "reconnect-overlay"
            p.detail = "Attempt \(attempt) · typing paused"
        case .failed(let error):
            p.placement = .card
            p.dimsTerminal = true
            p.title = "Can't connect to \(hostName)"
            p.detail = Notice.sanitize(error.message, limit: Self.maxDetailLength)
            p.actions = [.retry]
            if error.kind == .authFailed { p.actions.append(.editHost) }
            if error.kind == .keyMissing { p.actions.append(.openKeys) }
            p.accessibilityIdentifier = "connection-error"
        case .disconnected(let exitStatus):
            p.placement = .strip
            p.title = "Disconnected"
            p.detail = exitStatus.map { "Session ended (exit status \($0))" }
            p.actions = [.reconnect]
            p.accessibilityIdentifier = "disconnected-card"
        }
        return p
    }

    private static let maxDetailLength = 300

    /// Whole seconds until `until`, rounded up, never negative.
    public static func countdownSeconds(until: Date, now: Date) -> Int {
        max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// Detail line at `now`; only the reconnecting countdown depends on time.
    public func detail(at now: Date) -> String? {
        guard let attempt else { return detail }
        var parts = ["Attempt \(attempt)"]
        if let retryAt {
            parts.append("retrying in \(Self.countdownSeconds(until: retryAt, now: now))s")
        }
        parts.append("typing paused")
        return parts.joined(separator: " · ")
    }
}
