import ShuaiApp
import ShuaiTerminal
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
    @State private var showTerminalDebug = ProcessInfo.processInfo.arguments.contains("-debugTerminal")
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            HostListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        #if DEBUG
        .overlay(alignment: .bottomLeading) { if DebugLaunch.agentFixture { FixtureLogProbe() } }
        #endif
        .sheet(item: Binding(get: { model.modal }, set: { if $0 == nil { model.dismissModal() } })) { route in
            modalContent(route)
        }
        .overlay(alignment: .bottom) { NotificationOptInBanner() }
        .overlay(alignment: .top) {
            // Without a selected host there is no terminal screen to show notices (e.g. a link to an unknown host).
            if model.selection.flatMap({ model.hosts.host(id: $0) }) == nil {
                NoticeStackView().padding()
            }
        }
        // The terminal is first responder; without this its software keyboard stays up under a sheet
        // and covers half of it on smaller iPads.
        .onChange(of: model.hasSheetOpen) { _, open in
            if open { Self.resignFirstResponder() }
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showTerminalDebug) {
            NavigationStack {
                TerminalDebugScreen().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { showTerminalDebug = false } }
                }
            }
        }
        .task { await DebugLaunch.applyIfRequested(model: model) }
        #endif
    }

    @ViewBuilder private func modalContent(_ route: ModalRoute) -> some View {
        switch route {
        case .newHost:
            HostEditorView(target: .new)
        case .editHost(let id):
            if let host = model.hosts.host(id: id) { HostEditorView(target: .edit(host)) }
        case .settings:
            SettingsView()
        case .keys:
            NavigationStack { KeysView(placement: .sheetRoot) }
        case .quickSwitcher:
            if let q = model.quickSwitcher { QuickSwitcherView(switcher: q) }
        case .agentInstall:
            if let req = model.agentInstall {
                AgentInstallSheet(model: req.model, hostName: req.host.name) { model.closeAgentInstall() }
            }
        }
    }

    @MainActor private static func resignFirstResponder() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selection, let host = model.hosts.host(id: id) {
            TerminalScreen(host: host).id(host.id)
        } else {
            ContentUnavailableView {
                Label("No host selected", systemImage: "terminal")
            } description: {
                Text(model.hosts.hosts.isEmpty ? "Add a server to start a terminal session." : "Choose a host from the sidebar.")
            } actions: {
                if model.hosts.hosts.isEmpty {
                    Button("Add your first host") { model.request(.newHost) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("add-first-host")
                }
            }
        }
    }
}

struct HostListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: HostProfile?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.hosts.hosts) { host in
                HostRow(
                    host: host, status: model.sessions.status(for: host.id),
                    agent: model.agentHub.status(for: host.id), waiting: model.agentHub.waitingCount(for: host.id))
                    .tag(host.id)
                    .accessibilityIdentifier("host-row-\(host.name)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = host } label: { Label("Delete", systemImage: "trash") }
                        Button { model.request(.editHost(host.id)) } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { model.request(.editHost(host.id)) }
                        let connected = model.sessions.existingController(for: host.id)?.agentRemote != nil
                        Button("Enable AI integration…", systemImage: "sparkles") {
                            model.presentAgentInstall(host: host, uninstall: false)
                        }
                        .disabled(!connected)
                        Button("Sync notification settings", systemImage: "arrow.triangle.2.circlepath") {
                            model.syncNotificationSettings(host: host)
                        }
                        .disabled(!connected || !model.agentHub.status(for: host.id).isInstalled)
                        Button("Remove AI integration…", systemImage: "sparkles.slash") {
                            model.presentAgentInstall(host: host, uninstall: true)
                        }
                        .disabled(!connected)
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = host }
                    }
                if let controller = model.sessions.existingController(for: host.id) {
                    if controller.tmux.topology != nil {
                        TmuxHostTree(host: host, controller: controller)
                    } else if TmuxTree.showsLoadingPlaceholder(
                        session: controller.state, tmuxEnabled: host.tmux.enabled && !controller.tmuxMissing, monitor: controller.tmux.state, hasTopology: false)
                    {
                        TmuxLoadingRow()
                    }
                }
            }
        }
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
        .navigationTitle("shuai")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.openQuickSwitcher() } label: { Label("Quick Switcher", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("quick-switcher-button")
                Button { model.request(.keys) } label: { Label("Keys", systemImage: "key") }
                    .accessibilityIdentifier("keys-button")
                Button { model.request(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings-button")
                Button { model.request(.newHost) } label: { Label("Add Host", systemImage: "plus") }
                    .accessibilityIdentifier("add-host-button")
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
    }
}

struct HostRow: View {
    let host: HostProfile
    let status: SessionState.Status
    var agent: AgentHostStatus = .unknown
    var waiting = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .accessibilityLabel(status.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline)
                Text(host.displayTarget).font(.caption).foregroundStyle(.secondary)
                if agent != .unknown {
                    Label(agent.label, systemImage: agentSymbol)
                        .font(.caption2)
                        .foregroundStyle(agentColor)
                        .accessibilityIdentifier("host-agent-status")
                }
            }
            Spacer()
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .accessibilityLabel("\(waiting) waiting for you")
                    .accessibilityIdentifier("host-waiting-count")
            }
        }
    }

    private var agentSymbol: String {
        switch agent {
        case .installed: "sparkles"
        case .outdated: "arrow.up.circle"
        default: "sparkles.slash"
        }
    }

    private var agentColor: Color {
        switch agent {
        case .installed: .secondary
        case .outdated: .orange
        default: .secondary
        }
    }
}

/// Non-modal opt-in for background notifications. Unlike an alert it never covers a permission card: it waits
/// until no card is pending (`NotificationOptInPolicy`).
struct NotificationOptInBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if NotificationOptInPolicy.isVisible(
            offerPending: model.showNotificationExplainer, pendingPermissionCards: model.agentHub.pendingPermissions.count)
        {
            VStack(alignment: .leading, spacing: 8) {
                Label("Get notified in the background?", systemImage: "bell.badge").font(.headline)
                Text("shuai can send a notification when Claude needs your approval or finishes while the app is in the background. iOS suspends apps soon after you leave them, so this is best effort.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Not now") { model.declineNotifications() }
                        .accessibilityIdentifier("notify-not-now")
                    Spacer()
                    Button("Enable") { model.enableNotifications() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("notify-enable")
                }
            }
            .padding(14)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notify-optin")
        }
    }
}
