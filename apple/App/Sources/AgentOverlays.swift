import ShuaiApp
import ShuaiCore
import SwiftUI

/// One in-app banner: used for agent transitions and for OSC 9/777 terminal notifications.
/// Auto-hides after 4 s; tapping runs `onTap`.
struct InAppBanner: View {
    let content: BannerContent
    /// Changes when a new banner replaces the old one (restarts the auto-hide timer).
    let token: AnyHashable
    var onTap: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: content.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: content.title).font(.headline).lineLimit(1)
                if !content.message.isEmpty { Text(verbatim: content.message).font(.subheadline).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { onTap?(); dismiss() }
        .task(id: token) {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notification-banner")
    }
}

/// Top banner for the newest live agent transition of any host.
struct AgentBannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.agentHub.banners
        if let banner = queue.banners.last(where: BannerContent.isShownAsBanner) {
            let target = model.agentHub.target(for: banner.key)
            let hostName = target.flatMap { model.hosts.host(id: $0.profileID)?.name } ?? banner.key.host
            InAppBanner(
                content: BannerContent.make(banner, hostName: hostName, session: target?.session), token: banner.id,
                onTap: { model.jump(toBannerKey: banner.key) }, dismiss: { queue.dismiss(banner.id) }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("agent-banner")
        }
    }
}

/// Pending permission requests of all hosts, stacked top-trailing over the terminal. Limited to
/// about half the height so the bottom rows (the prompt) stay visible; scrolls when longer.
struct PermissionCardStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.agentHub.pendingPermissions
        if !pending.isEmpty {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(pending.enumerated()), id: \.element.id) { index, p in
                            PermissionCardView(
                                item: p.item, answering: model.agentHub.answering(p),
                                errorMessage: model.agentHub.lastError(for: p),
                                contextLabel: model.permissionContext(p),
                                onShow: { Task { await model.jumpToPane(profileID: p.profileID, paneID: p.paneID) } },
                                enablesShortcuts: index == 0
                            ) { allow, message in
                                Task { await model.agentHub.respond(p, allow: allow, message: message) }
                            }
                            .shadow(radius: 6, y: 2)
                        }
                    }
                    .padding(10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: min(380, geo.size.width), height: geo.size.height * 0.55, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .allowsHitTesting(true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("permission-stack")
        }
    }
}
