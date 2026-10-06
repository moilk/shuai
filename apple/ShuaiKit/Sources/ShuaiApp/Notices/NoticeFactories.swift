import Foundation

/// Notices raised by the app model itself. Pure: plain values in, `Notice` out.
extension Notice {
    /// The message of a deep link that could not be followed; nil when there is nothing to say.
    public static func deepLink(_ outcome: DeepLinkOutcome) -> Notice? {
        guard case .notice(let message) = outcome else { return nil }
        return Notice(
            severity: .warning, source: .deepLink, scope: .app, text: message,
            symbol: "link.badge.plus", key: "deeplink")
    }

    /// An OSC 9/777 notification. The remote controls both strings, so the notice is always
    /// attributed to the host (never to the remote title) and stays `.info`, below real agent
    /// attention. Emptiness is decided after sanitizing; nil when nothing readable remains.
    public static func terminal(title: String, body: String, hostName: String, hostID: UUID) -> Notice? {
        let t = sanitize(title, limit: textLimit)
        let b = sanitize(body, limit: textLimit)
        let text = t.isEmpty ? b : (b.isEmpty ? t : "\(t): \(b)")
        guard !text.isEmpty else { return nil }
        return Notice(
            severity: .info, source: .terminal, scope: .host(hostID), title: "\(hostName) \u{00B7} Terminal",
            text: text, symbol: "bell", key: "osc:\(hostID.uuidString)")
    }

    public static func pushSyncKey(hostID: UUID) -> String { "push-sync:\(hostID.uuidString)" }

    /// Result of syncing notification settings to one host; nil when nothing changed.
    /// Failure text can quote the request (ntfy topic, token) or remote paths, so secrets are
    /// removed and home directories collapsed before the notice caps it. Shown app-wide because
    /// the sync is started from a menu.
    public static func pushSync(
        _ result: PushSyncOutcome, hostName: String, hostID: UUID, redacting secrets: [String]
    ) -> Notice? {
        let key = pushSyncKey(hostID: hostID)
        switch result {
        case .upToDate:
            return nil
        case .synced:
            return Notice(
                severity: .success, source: .app, text: "Notification settings synced to \(hostName).",
                symbol: "checkmark.circle", key: key)
        case .failed(let message):
            let clean = collapseHomePaths(redact(message, secrets: secrets, limit: textLimit))
            return Notice(
                severity: .warning, source: .app, text: "Could not sync to \(hostName): \(clean)",
                symbol: "exclamationmark.triangle", key: key)
        }
    }

    /// Sanitizes untrusted text, then removes every secret (longest first, case-insensitive) so a
    /// secret cannot hide behind invisible characters or survive as a cap-truncated prefix.
    public static func redact(_ text: String, secrets: [String], limit: Int) -> String {
        var out = sanitize(text, limit: 100_000)
        let clean = secrets.map { sanitize($0, limit: 1_000) }.filter { !$0.isEmpty }
        for secret in clean.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "…", options: .caseInsensitive)
        }
        return sanitize(out, limit: limit)
    }

    /// `/home/<name>`, `/Users/<name>` and `/root` become `~`.
    public static func collapseHomePaths(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<![\w])(?:/(?:home|Users)/[^/\s'"`:;,)]+|/root(?![\w.-]))"#, with: "~", options: .regularExpression)
    }

    /// What to show and what to retract after syncing several hosts: one warning per failed host,
    /// the success summary only when none failed, and the stale failure of every host that took
    /// the settings removed.
    public static func pushSyncSummary(
        _ results: [(hostID: UUID, hostName: String, outcome: PushSyncOutcome)], redacting secrets: [String]
    ) -> PushSyncReport {
        guard !results.isEmpty else { return PushSyncReport(post: [noSyncTargets], retractKeys: []) }
        var post: [Notice] = []
        var retract: [String] = []
        for r in results {
            if case .failed = r.outcome {
                if let n = pushSync(r.outcome, hostName: r.hostName, hostID: r.hostID, redacting: secrets) { post.append(n) }
            } else {
                retract.append(pushSyncKey(hostID: r.hostID))
            }
        }
        if post.isEmpty { post.append(pushSyncedAll) }
        return PushSyncReport(post: post, retractKeys: retract)
    }

    /// Every connected host took the settings.
    public static var pushSyncedAll: Notice {
        Notice(
            severity: .success, source: .app, text: "Notification settings synced.",
            symbol: "checkmark.circle", key: "push-sync")
    }

    /// "Sync to connected hosts" with no host able to take them.
    public static var noSyncTargets: Notice {
        Notice(
            severity: .info, source: .app,
            text: "No connected host has the AI integration. Settings sync when one connects.",
            symbol: "info.circle", key: "push-sync")
    }

    public static var noAttention: Notice {
        Notice(
            severity: .info, source: .app, text: "No agent needs your attention.",
            symbol: "checkmark.circle", key: "no-attention")
    }
}

public struct PushSyncReport: Sendable {
    public var post: [Notice]
    public var retractKeys: [String]
}

extension NoticeCenter {
    public func apply(_ report: PushSyncReport) {
        for key in report.retractKeys { retract(key: key) }
        for n in report.post { post(n) }
    }
}
