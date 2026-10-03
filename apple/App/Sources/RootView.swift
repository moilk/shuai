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
        .sheet(item: $model.editor) { target in
            HostEditorView(target: target)
        }
        .sheet(isPresented: Binding(
            get: { model.quickSwitcher != nil }, set: { if !$0 { model.closeQuickSwitcher(activated: false) } })
        ) {
            if let q = model.quickSwitcher { QuickSwitcherView(switcher: q) }
        }
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
                HostRow(host: host, status: model.sessions.status(for: host.id))
                    .tag(host.id)
                    .accessibilityIdentifier("host-row-\(host.name)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = host } label: { Label("Delete", systemImage: "trash") }
                        Button { model.editor = .edit(host) } label: { Label("Edit", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { model.editor = .edit(host) }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = host }
                    }
                if let controller = model.sessions.existingController(for: host.id), controller.tmux.topology != nil {
                    TmuxHostTree(host: host, controller: controller)
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

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
                .accessibilityLabel(label)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline)
                Text(host.displayTarget).font(.caption).foregroundStyle(.secondary)
            }
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
