import Foundation

/// The one-line value on the Settings first page for the push page link. It carries the server
/// host only: never the topic, the token, or the URL's port, path or query.
public enum PushSettingsSummary {
    public static func text(enabled: Bool, serverText: String) -> String {
        guard enabled else { return "Off" }
        guard let host = NtfyServer.validate(serverText).url?.host, !host.isEmpty else { return "On" }
        return "On · \(host)"
    }

    @MainActor
    public static func text(for settings: PushSettings) -> String {
        text(enabled: settings.enabled, serverText: settings.serverText)
    }
}

extension NtfyTopic {
    static let maskedPlaceholder = "••••••••"

    /// `shuai-••••…wxyz`: the prefix and the last four characters, for showing a topic on screen
    /// (and to VoiceOver) without exposing it. Anything that is not a generated topic reveals nothing.
    public static func masked(_ topic: String) -> String {
        guard topic.hasPrefix(prefix), topic.count == prefix.count + 26,
              topic.dropFirst(prefix.count).allSatisfy({ alphabet.contains($0) })
        else { return maskedPlaceholder }
        return prefix + "••••…" + topic.suffix(4)
    }
}
