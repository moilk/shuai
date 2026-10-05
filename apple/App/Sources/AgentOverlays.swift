import ShuaiApp
import ShuaiCore
import SwiftUI

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
                // Sized to the cards (scrolls past 95% of the height) so the blank area stays tappable.
                .frame(width: min(380, geo.size.width))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: geo.size.height * 0.95, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .allowsHitTesting(true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("permission-stack")
        }
    }
}
