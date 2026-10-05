import Foundation
import ShuaiCore

/// What tapping a notice does.
public enum NoticeAction: Equatable, Sendable {
    case jumpToAgent(FfiSessionKey)
    case retryConnect(hostID: UUID)
}

/// A transient in-app message. Text is untrusted (terminal, tmux, remote stderr) and therefore
/// sanitized and length-capped on construction; render it with `Text(verbatim:)`.
public struct Notice: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info, success, attention, warning, error

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        /// Minimum time on screen in milliseconds.
        var baseDurationMs: UInt64 {
            switch self {
            case .info, .success: 5000
            case .attention: 6000
            case .warning: 8000
            case .error: 10000
            }
        }
    }

    public enum Source: Hashable, Sendable {
        case app, deepLink, session, tmux, terminal, agent
    }

    public enum Scope: Hashable, Sendable {
        case app
        case host(UUID)
    }

    public enum Lifetime: Equatable, Sendable {
        case auto
        case autoAfter(ms: UInt64)
        case sticky
    }

    public static let titleLimit = 80
    public static let textLimit = 300

    public let id: UUID
    public let severity: Severity
    public let source: Source
    public let scope: Scope
    public let title: String?
    public let text: String
    public let symbol: String
    public let action: NoticeAction?
    /// Dedupe key: a notice posted with an existing key replaces or coalesces with it.
    public let key: String
    public let lifetime: Lifetime
    /// How many identical posts this notice stands for.
    public internal(set) var count: Int

    public init(
        id: UUID = UUID(),
        severity: Severity,
        source: Source,
        scope: Scope = .app,
        title: String? = nil,
        text: String,
        symbol: String,
        action: NoticeAction? = nil,
        key: String,
        lifetime: Lifetime = .auto
    ) {
        self.id = id
        self.severity = severity
        self.source = source
        self.scope = scope
        let cleanTitle = title.map { Notice.sanitize($0, limit: Notice.titleLimit) }
        self.title = (cleanTitle?.isEmpty ?? true) ? nil : cleanTitle
        self.text = Notice.sanitize(text, limit: Notice.textLimit)
        self.symbol = symbol
        self.action = action
        self.key = key
        self.lifetime = lifetime
        self.count = 1
    }

    /// Identifier kept stable per source for UI tests.
    public var accessibilityIdentifier: String {
        switch source {
        case .app, .deepLink, .session, .tmux: "session-notice"
        case .terminal: "notification-banner"
        case .agent: "agent-banner"
        }
    }

    /// Milliseconds on screen once visible; nil for sticky notices.
    /// `max(base(severity), min(15 s, 2 s + 50 ms per character))`.
    public var duration: UInt64? {
        switch lifetime {
        case .sticky: return nil
        case .autoAfter(let ms): return ms
        case .auto:
            let reading = min(15000, 2000 + UInt64(text.count) * 50)
            return max(severity.baseDurationMs, reading)
        }
    }

    /// Makes untrusted text safe for display: drops control characters and bidi
    /// overrides/isolates, turns newlines and tabs into spaces, collapses whitespace, trims, and
    /// caps at `limit` characters (ellipsis included).
    public static func sanitize(_ s: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A, 0x0D:
                scalars.append(" ")
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069:
                continue
            default:
                scalars.append(u)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard limit > 0 else { return "" }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
