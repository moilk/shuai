import ShuaiApp
import SwiftUI

/// The one renderer of `NoticeCenter.queue`. It owns no timers: the center expires notices and
/// this view only reflects the queue. Notice text is untrusted, so it is shown verbatim.
/// Exactly one instance is mounted at a time (the terminal screen, or the root view when no host
/// is selected), which is why it can forward the pending permission card count itself.
struct NoticeStackView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.notices.queue
        return VStack(spacing: 8) {
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
                model.selection = hostID
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

    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44

    private var severityLabel: String {
        switch notice.severity {
        case .info: "Info"
        case .success: "Success"
        case .attention: "Attention"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
            // The minimum lives in the label so the whole square is tappable.
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(minWidth: minTarget, minHeight: minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("notice-dismiss")
        }
        .padding(padding)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Icon, text and count are one accessibility element; the dismiss button stays separate.
    private var content: some View {
        HStack(alignment: .top, spacing: spacing) {
            Image(systemName: notice.symbol)
            VStack(alignment: .leading, spacing: 2) {
                if let title = notice.title {
                    Text(verbatim: title).font(.subheadline.weight(.semibold))
                }
                Text(verbatim: notice.text).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if notice.count > 1 {
                Text(verbatim: "×\(notice.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if notice.action != nil { activate() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(severityLabel). \(notice.title.map { $0 + ". " } ?? "")\(notice.text)"))
        .accessibilityValue(Text(verbatim: notice.count > 1 ? "\(notice.count) times" : ""))
        .accessibilityIdentifier(notice.accessibilityIdentifier)
        .accessibilityAction(named: "Dismiss", dismiss)
        .accessibilityAction { if notice.action != nil { activate() } }
    }
}
