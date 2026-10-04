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
        .sheet(item: $model.editor) { target in
            HostEditorView(target: target)
        }
        .sheet(isPresented: Binding(
            get: { model.quickSwitcher != nil }, set: { if !$0 { model.closeQuickSwitcher(activated: false) } })
        ) {
            if let q = model.quickSwitcher { QuickSwitcherView(switcher: q) }
        }
        .sheet(item: $model.agentInstall) { req in
            AgentInstallSheet(model: req.model, hostName: req.host.name) { model.closeAgentInstall() }
        }
        .overlay(alignment: .bottom) { NotificationOptInBanner() }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.showKeys) { NavigationStack { KeysView() } }
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
                    Button("Add your first host") { model.editor = .new }
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
                        Button { model.editor = .edit(host) } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { model.editor = .edit(host) }
                        let connected = model.sessions.existingController(for: host.id)?.agentRemote != nil
                        Button("Enable AI integration…", systemImage: "sparkles") {
                            model.presentAgentInstall(host: host, uninstall: false)
                        }
                        .disabled(!connected)
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
                    Button("Add your first host") { model.editor = .new }
                        .accessibilityIdentifier("sidebar-add-first-host")
                }
            }
        }
        .navigationTitle("shuai")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.openQuickSwitcher() } label: { Label("Quick Switcher", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("quick-switcher-button")
                Button { model.showKeys = true } label: { Label("Keys", systemImage: "key") }
                    .accessibilityIdentifier("keys-button")
                Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings-button")
                Button { model.editor = .new } label: { Label("Add Host", systemImage: "plus") }
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
            Circle().fill(color).frame(width: 10, height: 10)
                .accessibilityLabel(label)
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
        case .outdated: "arrow.triangle.2.circlepath"
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

    private var color: Color {
        switch status {
        case .off: .gray.opacity(0.5)
        case .busy: .yellow
        case .connected: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private var label: String {
        switch status {
        case .off: "Not connected"
        case .busy: "Connecting"
        case .connected: "Connected"
        case .warning: "Reconnecting"
        case .error: "Connection failed"
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
