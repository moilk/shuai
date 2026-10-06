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

    /// Makes untrusted text safe for display: removes complete ANSI CSI and OSC sequences, drops control, format (bidi, zero-width, tag) and
    /// blank-filler characters, turns newlines and tabs into spaces, collapses whitespace, trims,
    /// bounds combining marks (at most 4 scalars per cluster), and caps at `limit` characters
    /// (ellipsis included). One pass that stops reading input once the cap is exceeded.
    public static func sanitize(_ s: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let budget = limit * 8
        var out = String.UnicodeScalarView()
        var emitted = 0
        var sinceCheck = 0
        var clusterScalars = 0
        var pendingSpace = false
        var truncated = false

        let scalars = s.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let u = scalars[index]
            index = scalars.index(after: index)
            if u.value == 0x1B {
                index = endOfEscapeSequence(in: scalars, after: index, budget: budget)
                continue
            }
            let v = u.value
            if (v < 0x20 || (0x7F...0x9F).contains(v)) && v != 0x09 && v != 0x0A && v != 0x0D { continue }
            if u.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if isInvisible(u) { continue }
            let isMark = isCombiningMark(u)
            if isMark && clusterScalars >= maxClusterScalars { continue }
            if pendingSpace {
                out.append(" ")
                emitted += 1
                pendingSpace = false
                clusterScalars = 0
            }
            out.append(u)
            emitted += 1
            clusterScalars = isMark ? clusterScalars + 1 : 1
            sinceCheck += 1
            if emitted > budget { truncated = true; break }
            if sinceCheck >= limit {
                sinceCheck = 0
                if String(out).count > limit { truncated = true; break }
            }
        }

        let chars = Array(String(out))
        guard truncated || chars.count > limit else { return String(chars) }
        var kept = chars.prefix(min(chars.count, limit - 1))
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        return String(kept) + "…"
    }

    private static let maxClusterScalars = 4

    /// Where reading resumes after an ESC at `index - 1`: past a complete CSI (`[` parameters,
    /// final byte 0x40...0x7E) or OSC (`]` ... BEL or ST) sequence, otherwise right after the ESC
    /// itself. A sequence whose end is not found within `budget` scalars is not swallowed.
    private static func endOfEscapeSequence(
        in scalars: String.UnicodeScalarView, after index: String.UnicodeScalarView.Index, budget: Int
    ) -> String.UnicodeScalarView.Index {
        guard index < scalars.endIndex else { return index }
        let kind = scalars[index]
        guard kind == "[" || kind == "]" else { return index }
        var i = scalars.index(after: index)
        var scanned = 0
        while i < scalars.endIndex, scanned < budget {
            let v = scalars[i].value
            i = scalars.index(after: i)
            scanned += 1
            if kind == "[" {
                if (0x40...0x7E).contains(v) { return i }
                if !(0x20...0x3F).contains(v) { return index }
            } else {
                if v == 0x07 || v == 0x9C { return i }
                if v == 0x1B, i < scalars.endIndex, scalars[i] == "\\" { return scalars.index(after: i) }
            }
        }
        return index
    }

    /// Control, format (bidi, zero-width, tags, ...) and blank-filler scalars. ZWNJ and ZWJ stay
    /// because emoji sequences and several scripts need them.
    private static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x200C, 0x200D: return false
        case 0xAD, 0x61C, 0x115F, 0x1160, 0x180E, 0x3164, 0xFFA0, 0xE0000...0xE007F: return true
        default: break
        }
        switch u.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    private static func isCombiningMark(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}
