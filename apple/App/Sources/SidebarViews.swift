import ShuaiApp
import SwiftUI

/// The sidebar: one `List` over `SidebarModel.rows` (hosts, sessions, windows, panes). Hosts are
/// the only selectable rows; tmux rows are buttons that act on tmux.
struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: HostProfile?
    @State private var renaming: WindowRenaming?
    @State private var newName = ""

    /// A model row with the session it sits under (window menus act on that session).
    private struct Entry: Identifiable {
        let row: SidebarRow
        let sessionID: String?
        var id: String { row.id }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(entries()) { entry in
                rowView(entry)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(model.settings.theme.chrome.surface))
        .foregroundStyle(Color(model.settings.theme.chrome.text))
        .toolbarBackground(Color(model.settings.theme.chrome.surface), for: .navigationBar, .bottomBar)
        .overlay {
            if model.hosts.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No hosts", systemImage: "server.rack")
                } actions: {
                    Button("Add your first host") { model.request(.newHost) }
                        .accessibilityIdentifier("sidebar-add-first-host")
                }
            }
        }
        // The brand sits leading as a toolbar item; the system's centred title is empty.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            brandToolbarItem
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.openQuickSwitcher() } label: { Label("Quick Switcher", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("quick-switcher-button")
            }
            // System bottom bar: a flexible space, then New Host and Settings together at the trailing
            // side. Keys stays reachable through Settings, the app menu, the host editor and the
            // connection card.
            if #available(iOS 26, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(placement: .bottomBar) { newHostButton }
            ToolbarItem(placement: .bottomBar) { settingsButton }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "host")?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let h = pendingDelete { model.delete(h) }
                pendingDelete = nil
            }
        } message: {
            Text("The saved password (if any) is removed too. tmux sessions on the server keep running.")
        }
        .windowRenameAlert(renaming: $renaming, newName: $newName)
    }

    /// The brand title without the glass capsule iOS 26 draws around toolbar items.
    @ToolbarContentBuilder
    private var brandToolbarItem: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarLeading) { SidebarBrandTitle() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { SidebarBrandTitle() }
        }
    }

    private var newHostButton: some View {
        Button { model.request(.newHost) } label: { Label("New Host", systemImage: "plus") }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("add-host-button")
    }

    private var settingsButton: some View {
        Button { model.request(.settings) } label: { Label("Settings", systemImage: "gearshape") }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("settings-button")
    }

    // MARK: rows

    private func inputs() -> [SidebarHostInput] {
        model.hosts.hosts.map { host in
            let controller = model.sessions.existingController(for: host.id)
            return SidebarHostInput(
                id: host.id, name: host.name, target: host.displayTarget, status: model.sessions.status(for: host.id),
                session: controller?.state, tmuxEnabled: host.tmux.enabled && !(controller?.tmuxMissing ?? false),
                monitor: controller?.tmux.state ?? .idle, topology: controller?.tmux.topology,
                viewedSessionID: controller?.tmux.viewedSessionID, agent: model.agentHub.status(for: host.id),
                waiting: model.agentHub.waitingCount(for: host.id))
        }
    }

    private func entries() -> [Entry] {
        var session: String?
        return SidebarModel.rows(inputs(), expansion: model.sidebarExpansion.expansion, badges: model.badges).map { row in
            switch row {
            case .host, .loading: session = nil
            case .session(let s): session = s.row.id
            case .window, .pane: break
            }
            return Entry(row: row, sessionID: session)
        }
    }

    @ViewBuilder
    private func rowView(_ entry: Entry) -> some View {
        switch entry.row {
        case .host(let h):
            if let host = model.hosts.host(id: h.id) {
                SidebarHostRow(row: h) { model.sidebarExpansion.toggle(.host(h.id), default: true) }
                    .tag(h.id)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = host } label: { Label("Delete", systemImage: "trash") }
                        Button { model.request(.editHost(host.id)) } label: { Label("Edit", systemImage: "pencil") }
                            .tint(Color.accentColor)
                    }
                    .contextMenu { hostMenu(host) }
            }
        case .loading:
            TmuxLoadingRow().sidebarIndent(depth: entry.row.depth)
        case .session(let s):
            SidebarSessionRow(row: s) {
                model.sidebarExpansion.toggle(.session(host: s.host, name: s.name), default: s.row.viewed)
            }
            .sidebarIndent(depth: entry.row.depth)
        case .window(let w):
            SidebarWindowRow(row: w, sessionID: entry.sessionID ?? "") {
                newName = w.row.name
                renaming = WindowRenaming(host: w.host, windowID: w.row.id)
            }
            .sidebarIndent(depth: entry.row.depth)
        case .pane(let p):
            SidebarPaneRow(row: p).sidebarIndent(depth: entry.row.depth)
        }
    }

    @ViewBuilder
    private func hostMenu(_ host: HostProfile) -> some View {
        let connected = model.sessions.existingController(for: host.id)?.agentRemote != nil
        let connection = HostConnectionMenu.item(for: model.sessions.existingController(for: host.id)?.state)
        Button(connection.title, systemImage: connection.symbol) {
            switch connection {
            case .connect:
                // Selecting shows the terminal, where host key and password prompts surface.
                model.selection = host.id
                Task { await model.sessions.controller(for: host).connect() }
            case .disconnect:
                Task { await model.sessions.controller(for: host).disconnect() }
            }
        }
        .accessibilityIdentifier("host-connection-action")
        Button("Edit", systemImage: "pencil") { model.request(.editHost(host.id)) }
        Section("AI integration") {
            AIMenuButton(title: "Enable AI integration\u{2026}", symbol: "sparkles", explainsDisabled: !connected) {
                model.presentAgentInstall(host: host, uninstall: false)
            }
            .disabled(!connected)
            AIMenuButton(title: "Sync notification settings", symbol: "arrow.triangle.2.circlepath", explainsDisabled: !connected) {
                model.syncNotificationSettings(host: host)
            }
            .disabled(!connected || !model.agentHub.status(for: host.id).isInstalled)
            AIMenuButton(title: "Remove AI integration\u{2026}", symbol: "sparkles.slash", explainsDisabled: !connected) {
                model.presentAgentInstall(host: host, uninstall: true)
            }
            .disabled(!connected)
        }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = host }
    }
}

/// The leading brand title of the sidebar's top bar. It scales with Dynamic Type and is the
/// screen's header for VoiceOver.
private struct SidebarBrandTitle: View {
    var body: some View {
        Text("shuai")
            .font(.title2.weight(.bold))
            .lineLimit(1)
            .fixedSize()
            // The system's toolbar inset leaves the text almost flush with the sidebar's edge; this
            // lines it up with the host rows below.
            .padding(.leading, 8)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("sidebar-title")
    }
}

/// A host menu item that says why it is disabled (the second `Text` renders as the subtitle).
private struct AIMenuButton: View {
    let title: String
    let symbol: String
    let explainsDisabled: Bool
    let action: () -> Void

    private static let reason = "Connect to this host first"

    var body: some View {
        Button(action: action) {
            Text(title)
            if explainsDisabled { Text(Self.reason) }
            Image(systemName: symbol)
        }
        // The subtitle is not always part of a menu item's accessibility label (iOS 26 drops it),
        // so the label carries the reason itself.
        .accessibilityLabel(explainsDisabled ? "\(title), \(Self.reason)" : title)
    }
}

// MARK: - Indentation

private struct SidebarIndent: ViewModifier {
    let depth: Int
    @ScaledMetric(relativeTo: .body) private var perLevel: CGFloat = 16
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        // Large text leaves little width: nesting stops growing past two levels.
        let levels = typeSize.isAccessibilitySize ? min(depth, 2) : depth
        content.padding(.leading, perLevel * CGFloat(levels))
    }
}

extension View {
    fileprivate func sidebarIndent(depth: Int) -> some View { modifier(SidebarIndent(depth: depth)) }
}

// MARK: - Rows

private struct SidebarChevron: View {
    let expanded: Bool
    let label: String
    let identifier: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(minWidth: minTarget, minHeight: minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct SidebarHostRow: View {
    let row: HostRowModel
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                // One element for status, name and target: a >= 44 pt tap area that VoiceOver reads as a sentence.
                HStack(spacing: 10) {
                    Image(systemName: row.status.symbol).foregroundStyle(row.status.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.headline)
                        Text(row.target).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: minTarget, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityValue(row.accessibilityValue)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("host-row-\(row.name)")
                .accessibilityActionIf(row.hasChildren, named: row.toggleLabel, toggle)
                if row.agent != .unknown {
                    Label(row.agent.label, systemImage: agentSymbol)
                        .font(.caption2)
                        .foregroundStyle(agentColor)
                        .accessibilityIdentifier("host-agent-status")
                }
            }
            if let badge = row.aggregate {
                Image(systemName: badge.symbol)
                    .imageScale(.small)
                    .foregroundStyle(badge.tint.color)
                    .accessibilityLabel(badge.label)
                    .accessibilityIdentifier("host-aggregate-badge")
            }
            if row.waiting > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill").imageScale(.small)
                    Text("\(row.waiting)")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.orange, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.waiting) waiting for you")
                .accessibilityIdentifier("host-waiting-count")
            }
            if row.hasChildren {
                SidebarChevron(
                    expanded: row.isExpanded, label: row.toggleLabel, identifier: "host-toggle-\(row.name)", action: toggle)
            }
        }
    }

    private var agentColor: Color {
        if case .outdated = row.agent { .orange } else { .secondary }
    }

    private var agentSymbol: String {
        switch row.agent {
        case .installed: "sparkles"
        case .outdated: "arrow.up.circle"
        default: "sparkles.slash"
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func accessibilityActionIf(_ condition: Bool, named name: String, _ action: @escaping () -> Void) -> some View {
        if condition { accessibilityAction(named: name, action) } else { self }
    }
}

private struct SidebarSessionRow: View {
    @Environment(AppModel.self) private var model
    let row: SessionRowModel
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44

    var body: some View {
        let viewed = row.row.viewed
        HStack(spacing: 0) {
            Button {
                model.runTmux(host: row.host) { try await $0.switchSession(row.row.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewed ? "rectangle.stack.fill" : "rectangle.stack")
                        .foregroundStyle(viewed ? Color.accentColor : .secondary)
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    BadgeView(badge: row.badge)
                }
                .frame(minHeight: minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.accessibilityValue)
            .accessibilityAddTraits(viewed ? .isSelected : [])
            .accessibilityIdentifier("tmux-session-\(row.name)")
            .contextMenu { TmuxSessionMenu(host: row.host, sessionID: row.row.id) }
            if row.hasChildren {
                SidebarChevron(
                    expanded: row.isExpanded, label: row.isExpanded ? "Collapse" : "Expand",
                    identifier: "tmux-session-toggle-\(row.name)", action: toggle)
            }
        }
        // A secondary tint, not a second selection: hosts keep the list's system highlight.
        .listRowBackground(viewed ? Color.accentColor.opacity(0.12) : nil)
    }
}

private struct SidebarWindowRow: View {
    @Environment(AppModel.self) private var model
    let row: WindowRowModel
    let sessionID: String
    let rename: () -> Void

    var body: some View {
        let window = row.row
        Button {
            model.runTmux(host: row.host) { try await $0.selectWindow(window.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow").foregroundStyle(row.isCurrent ? Color.accentColor : .secondary)
                Text(window.title)
                    .font(.subheadline)
                    .fontWeight(row.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if window.zoomed {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if window.paneCount > 1 {
                    Text("\(window.paneCount)").font(.caption2).foregroundStyle(.secondary)
                }
                BadgeView(badge: window.badge)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("tmux-window-\(window.id)")
        .contextMenu { TmuxWindowMenu(host: row.host, sessionID: sessionID, window: window, rename: rename) }
    }
}

private struct SidebarPaneRow: View {
    @Environment(AppModel.self) private var model
    let row: PaneRowModel

    var body: some View {
        let pane = row.row
        Button {
            model.runTmux(host: row.host) { try await $0.selectPane(pane.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.isCurrent ? "circle.fill" : "circle")
                    .font(.caption2)
                    .imageScale(.small)
                    .foregroundStyle(row.isCurrent ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(pane.title).font(.caption).lineLimit(1)
                Spacer()
                BadgeView(badge: pane.badge)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("tmux-pane-\(pane.id)")
        .contextMenu { TmuxPaneMenu(host: row.host, paneID: pane.id) }
    }
}
