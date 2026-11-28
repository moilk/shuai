import ShuaiApp
import SwiftUI

/// The sidebar displays the host and tmux tree. Each row explicitly handles activation.
struct HostListView: View {
    let showsEmptyAction: Bool
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
        List {
            ForEach(entries()) { entry in
                rowView(entry)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(.chromeSurface)
        .toolbarBackground(.chromeSurface, for: .navigationBar, .bottomBar)
        .overlay {
            if model.hosts.hosts.isEmpty {
                if showsEmptyAction {
                    ContentUnavailableView {
                        Label("No hosts", systemImage: "server.rack")
                    } actions: {
                        Button("Add your first host") { model.request(.newHost) }
                            .accessibilityIdentifier("sidebar-add-first-host")
                    }
                } else {
                    Text("No saved hosts")
                        .font(.footnote)
                        .foregroundStyle(.chromeSecondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
        }
        // The brand sits leading as a toolbar item; the system's centred title is empty.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            brandToolbarItem
            ToolbarItem(placement: .topBarTrailing) {
                toolbarButton("Quick Switcher", symbol: "magnifyingglass", identifier: "quick-switcher-button") {
                    model.openQuickSwitcher()
                }
            }
            // System bottom bar: a flexible space, then New Host and Settings together at the trailing
            // side. Keys stays reachable through Settings, the app menu, the host editor and the
            // connection card.
            if #available(iOS 26, *) {
                ToolbarSpacer(.flexible, placement: .bottomBar)
            } else {
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
            ToolbarItem(placement: .bottomBar) {
                toolbarButton("New Host", symbol: "plus", identifier: "add-host-button") { model.request(.newHost) }
            }
            ToolbarItem(placement: .bottomBar) {
                toolbarButton("Settings", symbol: "gearshape", identifier: "settings-button") { model.request(.settings) }
            }
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

    private func toolbarButton(
        _ title: LocalizedStringKey, symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        // Match the adaptive foreground color of the system sidebar toggle.
        Button(action: action) { Label(title, systemImage: symbol) }
            .labelStyle(.iconOnly)
            .tint(.primary)
            .accessibilityIdentifier(identifier)
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
                SidebarHostRow(
                    row: h, selected: model.selection == h.id,
                    select: {
                        model.selection = h.id
                        model.preferredCompactColumn = .detail
                        if let view = model.engine(for: host)?.view, view.window != nil {
                            _ = view.acquireProgrammaticFocus()
                        }
                    },
                    toggle: { model.sidebarExpansion.toggle(.host(h.id), default: true) })

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
        Button("Host Details", systemImage: "info.circle") { model.request(.editHost(host.id)) }
        let agent = model.agentHub.status(for: host.id)
        Section(agent == .unknown ? "AI Integration" : agent.label) {
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
                .foregroundStyle(.chromeSecondary)
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
    let selected: Bool
    let select: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 8) {
                    SidebarRowIcon(symbol: "server.rack", active: selected)
                    Text(row.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if row.waiting > 0 {
                        Label("\(row.waiting)", systemImage: "hand.raised.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.chromeWarning)
                            .accessibilityIdentifier("host-waiting-count")
                    } else if let badge = row.aggregate {
                        Image(systemName: badge.symbol)
                            .font(.caption)
                            .foregroundStyle(badge.tint.color)
                            .accessibilityIdentifier("host-aggregate-badge")
                    }
                }
                .frame(minHeight: 44)
                .padding(.leading, 8)
                .padding(.trailing, row.hasChildren ? 0 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.name)
            .accessibilityValue(
                [row.accessibilityValue, row.waiting == 0 ? row.aggregate?.label : nil, row.agent.label]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("host-row-\(row.name)")
            .accessibilityActionIf(row.hasChildren, named: row.toggleLabel, toggle)
            if row.hasChildren {
                SidebarChevron(
                    expanded: row.isExpanded, label: row.toggleLabel, identifier: "host-toggle-\(row.name)", action: toggle)
            }
        }
        .sidebarSurface(active: selected, primary: true)
    }
}

private struct SidebarRowIcon: View {
    let symbol: String
    let active: Bool
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .frame(width: size, height: size)
            .foregroundStyle(active ? AnyShapeStyle(.chromeAccent) : AnyShapeStyle(.chromeSecondary))
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    fileprivate func sidebarSurface(active: Bool, primary: Bool = false) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.chromeSelection)
                    .opacity(active ? (primary ? 1 : 0.55) : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }

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
                    SidebarRowIcon(symbol: "rectangle.stack", active: viewed)
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    BadgeView(badge: row.badge)
                }
                .frame(minHeight: minTarget)
                .padding(.leading, 8)
                .padding(.trailing, row.hasChildren ? 0 : 8)
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
        .sidebarSurface(active: viewed)
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
                SidebarRowIcon(symbol: "macwindow", active: row.isCurrent)
                Text(window.title)
                    .font(.subheadline)
                    .fontWeight(row.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                if window.zoomed {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2).foregroundStyle(.chromeSecondary)
                }
                Spacer()
                if window.paneCount > 1 {
                    Text("\(window.paneCount)").font(.caption2).foregroundStyle(.chromeSecondary)
                }
                BadgeView(badge: window.badge)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .sidebarSurface(active: row.isCurrent)
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
                SidebarRowIcon(symbol: "rectangle.split.2x1", active: row.isCurrent)
                Text(pane.title).font(.caption).lineLimit(1)
                Spacer()
                BadgeView(badge: pane.badge)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .sidebarSurface(active: row.isCurrent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityIdentifier("tmux-pane-\(pane.id)")
        .contextMenu { TmuxPaneMenu(host: row.host, paneID: pane.id) }
    }
}
