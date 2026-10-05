import ShuaiApp
import SwiftUI

/// The one renderer of `NoticeCenter.queue`. It owns no timers: the center expires notices and
/// this view only reflects the queue. Notice text is untrusted, so it is shown verbatim.
struct NoticeStackView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.notices.queue
        VStack(spacing: 8) {
            ForEach(queue.visible) { notice in
                NoticeRow(
                    notice: notice,
                    dismiss: { model.notices.dismiss(id: notice.id) },
                    activate: { activate(notice) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if queue.hiddenCount > 0 {
                Text(verbatim: "+\(queue.hiddenCount) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notice-more")
            }
        }
        .animation(.snappy, value: queue.visible)
        .onChange(of: model.agentHub.pendingPermissions.count, initial: true) { _, count in
            model.notices.setPendingPermissionCards(count)
        }
    }

    private func activate(_ notice: Notice) {
        switch notice.action {
        case .jumpToAgent(let key):
            model.notices.dismiss(id: notice.id)
            model.jump(toBannerKey: key)
        case .retryConnect(let hostID):
            model.notices.dismiss(id: notice.id)
            if let host = model.hosts.host(id: hostID) {
                Task { await model.sessions.controller(for: host).reconnect() }
            }
        case nil:
            break
        }
    }
}

private struct NoticeRow: View {
    let notice: Notice
    let dismiss: () -> Void
    let activate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title = notice.title {
                    Text(verbatim: title).font(.subheadline.weight(.semibold))
                }
                Text(verbatim: notice.text).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if notice.action != nil { activate() } }
            if notice.count > 1 {
                Text(verbatim: "×\(notice.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(notice.accessibilityIdentifier)
    }
}
