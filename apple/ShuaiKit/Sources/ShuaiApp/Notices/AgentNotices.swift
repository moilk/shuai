import Foundation
import ShuaiCore

/// Maps the agent's attention banners into notices. `AttentionBannerQueue` stays the domain
/// source (one banner per session, suppression for the viewed session, removal when a session
/// ends); the notice center only renders what the queue holds.
public enum AgentNotices {
    /// Notices for the banners that are not permission requests (those are cards). The notice id is
    /// the banner id, so repeated calls with the same banners reconcile to no change; the key is
    /// unique per session (the host is length-prefixed, so no host/session pair can collide).
    public static func make(
        _ banners: [AttentionBanner],
        resolve: (AttentionBanner) -> (hostName: String, session: FfiAgentSession?)
    ) -> [Notice] {
        banners.compactMap { banner in
            guard BannerContent.isShownAsBanner(banner) else { return nil }
            let target = resolve(banner)
            let content = BannerContent.make(banner, hostName: target.hostName, session: target.session)
            let hasMessage = !Notice.sanitize(content.message, limit: Notice.textLimit).isEmpty
            let severity: Notice.Severity
            switch banner.kind {
            case .needsInput: severity = .attention
            case .done: severity = .success
            case .failed: severity = .error
            case .permission: return nil
            }
            return Notice(
                id: banner.id, severity: severity, source: .agent, scope: .app,
                title: hasMessage ? content.title : nil,
                text: hasMessage ? content.message : content.title,
                symbol: content.symbol, action: .jumpToAgent(banner.key),
                key: "agent:\(banner.key.host.count):\(banner.key.host)|\(banner.key.sessionId)", lifetime: .auto)
        }
    }

    /// Makes the center's agent notices equal the queue's current banners.
    @MainActor
    public static func sync(
        queue: AttentionBannerQueue, center: NoticeCenter,
        resolve: (AttentionBanner) -> (hostName: String, session: FfiAgentSession?)
    ) {
        center.reconcile(source: .agent, with: make(queue.banners, resolve: resolve))
    }

    /// The user dismissed an agent notice: drop its banner too.
    @MainActor
    public static func dismissed(_ notice: Notice, in queue: AttentionBannerQueue) {
        guard notice.source == .agent else { return }
        queue.dismiss(notice.id)
    }
}
