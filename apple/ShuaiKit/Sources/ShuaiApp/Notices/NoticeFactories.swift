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

    /// Result of syncing notification settings to one host; nil when nothing changed.
    /// Failure text can quote the request (ntfy topic, token), so every secret is removed before
    /// the text is sanitized and capped. Shown app-wide because the sync is started from a menu.
    public static func pushSync(
        _ result: PushSyncOutcome, hostName: String, hostID: UUID?, redacting secrets: [String]
    ) -> Notice? {
        let key = hostID.map { "push-sync:\($0.uuidString)" } ?? "push-sync"
        switch result {
        case .upToDate:
            return nil
        case .synced:
            return Notice(
                severity: .success, source: .app, text: "Notification settings synced to \(hostName).",
                symbol: "checkmark.circle", key: key)
        case .failed(let message):
            var clean = message
            for secret in secrets where !secret.isEmpty {
                clean = clean.replacingOccurrences(of: secret, with: "…")
            }
            return Notice(
                severity: .warning, source: .app, text: "Could not sync to \(hostName): \(clean)",
                symbol: "exclamationmark.triangle", key: key)
        }
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
