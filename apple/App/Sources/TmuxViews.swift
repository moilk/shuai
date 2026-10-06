import ShuaiApp
import SwiftUI

extension PaneBadge.Tint {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .danger: .red
        }
    }
}

/// Badge slot of a row (agent state; empty until a `PaneBadgeProvider` supplies one).
struct BadgeView: View {
    let badge: PaneBadge?
    var body: some View {
        if let badge {
            Image(systemName: badge.symbol)
                .font(.caption)
                .foregroundStyle(badge.tint.color)
                .accessibilityLabel(badge.label)
                .accessibilityIdentifier("pane-badge")
        }
    }
}

/// Shown under a connected host until its tmux tree arrives (instead of an empty gap).
struct TmuxLoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading tmux\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tmux-loading")
    }
}

/// Session -> windows -> panes (when a window has several) of one connected host, inline in the
/// host list. Tapping selects it in tmux (and shows the host's terminal).
struct TmuxHostTree: View {
    @Environment(AppModel.self) private var model
    let host: HostProfile
    let controller: SessionController

    @State private var renaming: Renaming?
    @State private var newName = ""

    struct Renaming: Identifiable {
        let id: String
        let current: String
    }

    var body: some View {
        let actions = controller.tmuxActions
        let sessions = controller.tmux.topology.map {
            TmuxTree.sessions(topology: $0, viewedSessionID: controller.tmux.viewedSessionID, host: host.id, badges: model.badges)
        } ?? []
        ForEach(sessions) { session in
            Button { select { try await actions.switchSession(session.id) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.viewed ? "rectangle.stack.fill" : "rectangle.stack")
                        .foregroundStyle(session.viewed ? Color.accentColor : .secondary)
                    Text(session.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    BadgeView(badge: session.badge)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .accessibilityIdentifier("tmux-session-\(session.name)")

            ForEach(session.windows) { window in
                windowRow(window, in: session, actions: actions)
                ForEach(window.panes) { pane in
                    Button { select { try await actions.selectPane(pane.id) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pane.active && window.active ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                                .foregroundStyle(pane.active ? Color.accentColor : .secondary)
                            Text(pane.title).font(.caption).lineLimit(1)
                            Spacer()
                            BadgeView(badge: pane.badge)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 64)
                    .accessibilityIdentifier("tmux-pane-\(pane.id)")
                    .contextMenu {
                        Button("Split Right", systemImage: "rectangle.split.2x1") { select { try await actions.split(pane: pane.id, horizontal: true) } }
                        Button("Split Down", systemImage: "rectangle.split.1x2") { select { try await actions.split(pane: pane.id, horizontal: false) } }
                        Button("Close Pane", systemImage: "xmark.square", role: .destructive) {
                            model.selection = host.id
                            actions.requestKillPane(pane.id)
                        }
                    }
                }
            }
        }
        .alert("Rename Window", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).accessibilityIdentifier("rename-window-field")
            Button("Rename") {
                if let r = renaming { select { try await actions.renameWindow(r.id, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func windowRow(_ window: TmuxTree.WindowRow, in session: TmuxTree.SessionRow, actions: TmuxActions) -> some View {
        Button { select { try await actions.selectWindow(window.id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .foregroundStyle(window.active && session.viewed ? Color.accentColor : .secondary)
                Text(window.title)
                    .font(.subheadline)
                    .fontWeight(window.active ? .semibold : .regular)
                    .lineLimit(1)
                if window.zoomed { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if window.paneCount > 1 {
                    Text("\(window.paneCount)").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel("\(window.paneCount) panes")
                }
                BadgeView(badge: window.badge)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 40)
        .accessibilityIdentifier("tmux-window-\(window.id)")
        .accessibilityValue(window.active ? "active" : "")
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                newName = window.name
                renaming = Renaming(id: window.id, current: window.name)
            }
            Button("New Window", systemImage: "plus.rectangle") { select { try await actions.newWindow() } }
            if let pane = window.activePaneID {
                Button("Split Right", systemImage: "rectangle.split.2x1") { select { try await actions.split(pane: pane, horizontal: true) } }
                Button("Split Down", systemImage: "rectangle.split.1x2") { select { try await actions.split(pane: pane, horizontal: false) } }
            }
            if let pane = window.activePaneID, window.paneCount > 1 {
                Button("Close Pane", systemImage: "xmark.square", role: .destructive) {
                    model.selection = host.id
                    actions.requestKillPane(pane)
                }
            }
            Button("Close Window", systemImage: "xmark.rectangle", role: .destructive) {
                model.selection = host.id
                actions.requestKillWindow(window.id)
            }
        }
    }

    /// Makes this host's terminal the visible one, then runs the tmux action.
    private func select(_ body: @escaping @MainActor () async throws -> Void) {
        model.selection = host.id
        let actions = controller.tmuxActions
        Task { await actions.run(body) }
    }
}

/// Compact horizontal window strip above the terminal (shown while the sidebar is collapsed).
struct WindowTabStrip: View {
    @Environment(AppModel.self) private var model
    let host: HostProfile
    let controller: SessionController

    var body: some View {
        let actions = controller.tmuxActions
        if let session = actions.viewedSession {
            let rows = TmuxTree.windowRows(of: session, host: host.id, badges: model.badges)
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(rows) { w in
                            Button { Task { await actions.run { try await actions.selectWindow(w.id) } } } label: {
                                HStack(spacing: 4) {
                                    Text(w.title).lineLimit(1)
                                    if w.zoomed { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2) }
                                    BadgeView(badge: w.badge)
                                }
                                .font(.footnote.weight(w.active ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(w.active ? Color.accentColor.opacity(0.25) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("window-tab-\(w.id)")
                            .accessibilityValue(w.active ? "active" : "")
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Button { Task { await actions.run { try await actions.newWindow() } } } label: { Image(systemName: "plus") }
                    .padding(.horizontal, 10)
                    .accessibilityLabel("New Window")
                    .accessibilityIdentifier("window-tab-new")
            }
            .frame(height: 34)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("window-tab-strip")
        }
    }
}

/// ⌘K sheet: type to filter, ↑/↓ to move, ↩ to jump, esc to close.
struct QuickSwitcherView: View {
    @Environment(AppModel.self) private var model
    @Bindable var switcher: QuickSwitcherModel
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Jump to host, session, window or pane", text: $switcher.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(activate)
                    .accessibilityIdentifier("quick-switcher-field")
                // The minimum lives in the label so the whole square is tappable.
                Button { model.closeQuickSwitcher(activated: false) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: minTarget, minHeight: minTarget)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("quick-switcher-close")
            }
            .padding(padding)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(switcher.results.enumerated()), id: \.element.id) { index, item in
                        Button { pick(index) } label: { row(item) }
                            .buttonStyle(.plain)
                            .listRowBackground(index == switcher.selectedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            .id(item.id)
                            .accessibilityIdentifier("quick-switcher-row-\(index)")
                            .accessibilityValue(index == switcher.selectedIndex ? "selected" : "")
                    }
                }
                .listStyle(.plain)
                .onChange(of: switcher.selectedIndex) { _, i in
                    if switcher.results.indices.contains(i) { proxy.scrollTo(switcher.results[i].id) }
                }
                .overlay {
                    if switcher.results.isEmpty { ContentUnavailableView.search(text: switcher.query) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { switcher.moveDown(); return .handled }
        .onKeyPress(.upArrow) { switcher.moveUp(); return .handled }
    }

    private func row(_ item: SwitcherItem) -> some View {
        let badge = PaneBadge.aggregate(panes: item.paneIDs, host: item.hostID.uuidString, provider: model.badges)
        let detail = switcher.agentDetail(for: item)
        return HStack(spacing: 10) {
            Image(systemName: icon(item.kind)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let detail {
                    Text(verbatim: [AgentStatusBadge.label(for: detail.badge), detail.snippet].compactMap { $0 }.joined(separator: " \u{2014} "))
                        .font(.caption).foregroundStyle(detail.badge.tint.color).lineLimit(1)
                        .accessibilityIdentifier("quick-switcher-agent-\(item.id)")
                }
            }
            Spacer()
            BadgeView(badge: badge)
        }
        .contentShape(Rectangle())
    }

    private func icon(_ kind: SwitcherItem.Kind) -> String {
        switch kind {
        case .host: "server.rack"
        case .session: "rectangle.stack"
        case .window: "macwindow"
        case .pane: "rectangle.split.2x1"
        }
    }

    private func pick(_ index: Int) {
        while switcher.selectedIndex != index { switcher.moveDown() }
        activate()
    }

    private func activate() {
        guard let item = switcher.activate() else { return }
        model.closeQuickSwitcher(activated: true)
        Task { await model.jump(to: item) }
    }
}
