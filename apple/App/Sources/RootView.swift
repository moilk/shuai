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
        .chromeRoot(model.settings.theme.chrome)
        #if DEBUG
        .overlay(alignment: .bottomLeading) { if DebugLaunch.agentFixture { FixtureLogProbe() } }
        #endif
        .sheet(item: Binding(get: { model.modal }, set: { if $0 == nil { model.dismissModal() } })) { route in
            modalContent(route)
                .chromeRoot(model.settings.theme.chrome)
                .presentationBackground(.chromeSurface)
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
            HostEditorView(target: .new, keyIDs: model.keys.items.map(\.id))
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
                    .font(.footnote).foregroundStyle(.chromeSecondary)
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
            .chromeCard(cornerRadius: 14)
            .shadow(radius: 8, y: 2)
            .padding(.bottom, 24)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notify-optin")
        }
    }
}
