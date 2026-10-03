import Foundation
import ShuaiCore

/// What an in-app banner shows. One shape for agent transitions and OSC 9/777 terminal
/// notifications, so both render with the same view.
public struct BannerContent: Equatable, Sendable {
    public var title: String
    public var message: String
    public var symbol: String

    /// Permission requests are shown as cards, not banners.
    public static func isShownAsBanner(_ banner: AttentionBanner) -> Bool { !banner.kind.isPermission }

    public static func make(_ banner: AttentionBanner, hostName: String, session: FfiAgentSession?) -> BannerContent {
        let snippet = PaneAgentInfo.snippet(prompt: session?.lastPrompt, message: session?.lastMessage) ?? ""
        switch banner.kind {
        case .needsInput:
            return BannerContent(title: "\(hostName): needs your input", message: snippet, symbol: PaneBadge.needsInput.symbol)
        case .done:
            return BannerContent(title: "\(hostName): done", message: snippet, symbol: PaneBadge.done.symbol)
        case .failed(let error):
            return BannerContent(title: "\(hostName): failed", message: error, symbol: PaneBadge.failed.symbol)
        case .permission(_, let tool, let preview):
            return BannerContent(title: "\(hostName): needs approval", message: "\(tool): \(preview)", symbol: PaneBadge.needsPermission.symbol)
        }
    }

    /// An OSC 9/777 notification from the terminal.
    public static func make(title: String, body: String, hostName: String) -> BannerContent {
        BannerContent(title: title.isEmpty ? hostName : title, message: body, symbol: "bell")
    }
}

/// A local notification the app may post when it is not in the foreground.
public struct LocalNotificationContent: Equatable, Sendable {
    /// Same identifier for the same session: a newer transition replaces the older notification.
    public var identifier: String
    public var title: String
    public var body: String
    public var key: FfiSessionKey
    public var paneID: String?
}

public enum AttentionNotificationPolicy {
    /// The notification for a *live* tracker change, or nil (foreground app, or nothing that wants
    /// the user). iOS suspends the app soon after it backgrounds, so this is best effort.
    public static func content(
        for change: FfiTrackerChange, session: FfiAgentSession?, hostName: String, appActive: Bool
    ) -> LocalNotificationContent? {
        guard !appActive else { return nil }
        switch change {
        case .permissionRequested(let key, let request):
            return LocalNotificationContent(
                identifier: "permission-\(request.requestId)", title: "\(hostName): needs approval",
                body: "\(request.toolName): \(request.inputPreview)", key: key, paneID: session?.tmuxPane)
        case .stateChanged(let key, _, let to):
            let snippet = PaneAgentInfo.snippet(prompt: session?.lastPrompt, message: session?.lastMessage) ?? ""
            let (title, body): (String, String)
            switch to {
            case .needsInput: (title, body) = ("\(hostName): needs your input", snippet)
            case .done: (title, body) = ("\(hostName): done", snippet)
            case .failed(let error): (title, body) = ("\(hostName): failed", error)
            default: return nil
            }
            return LocalNotificationContent(
                identifier: "session-\(key.host)-\(key.sessionId)", title: title, body: body, key: key,
                paneID: session?.tmuxPane)
        case .sessionAdded, .sessionRemoved, .permissionCleared:
            return nil
        }
    }
}
