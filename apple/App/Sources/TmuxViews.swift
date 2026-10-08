import ShuaiApp
import SwiftUI

extension PaneBadge.Tint {
    var color: ChromeStyle {
        switch self {
        case .neutral: .chromeSecondary
        case .info: .chromeAccent
        case .success: .chromeSuccess
        case .warning: .chromeWarning
        case .danger: .chromeError
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
            Text("Loading tmux\u{2026}").font(.caption).foregroundStyle(.chromeSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tmux-loading")
    }
}

/// Window actions shared by sidebar rows and tabs. "New Window" targets the window's own session.
struct TmuxWindowMenu: View {
    @Environment(AppModel.self) private var model
    let host: UUID
    let sessionID: String
    let window: TmuxTree.WindowRow
    let rename: () -> Void

    var body: some View {
        Button("Rename\u{2026}", systemImage: "pencil", action: rename)
        Button("New Window", systemImage: "plus.rectangle") {
            model.runTmux(host: host) { try await $0.newWindow(inSession: sessionID) }
        }
        if let pane = window.activePaneID {
            Button("Split Right", systemImage: "rectangle.split.2x1") {
                model.runTmux(host: host) { try await $0.split(pane: pane, horizontal: true) }
            }
            Button("Split Down", systemImage: "rectangle.split.1x2") {
                model.runTmux(host: host) { try await $0.split(pane: pane, horizontal: false) }
            }
        }
        if let pane = window.activePaneID, window.paneCount > 1 {
            Button("Close Pane", systemImage: "xmark.square", role: .destructive) {
                model.requestKill(host: host) { $0.requestKillPane(pane) }
            }
        }
        Button("Close Window", systemImage: "xmark.rectangle", role: .destructive) {
            model.requestKill(host: host) { $0.requestKillWindow(window.id) }
        }
    }
}

/// Actions of one pane row.
struct TmuxPaneMenu: View {
    @Environment(AppModel.self) private var model
    let host: UUID
    let paneID: String

    var body: some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") {
            model.runTmux(host: host) { try await $0.split(pane: paneID, horizontal: true) }
        }
        Button("Split Down", systemImage: "rectangle.split.1x2") {
            model.runTmux(host: host) { try await $0.split(pane: paneID, horizontal: false) }
        }
        Button("Close Pane", systemImage: "xmark.square", role: .destructive) {
            model.requestKill(host: host) { $0.requestKillPane(paneID) }
        }
    }
}

/// Actions of one session row.
struct TmuxSessionMenu: View {
    @Environment(AppModel.self) private var model
    let host: UUID
    let sessionID: String

    var body: some View {
        Button("Switch to Session", systemImage: "rectangle.stack") {
            model.runTmux(host: host) { try await $0.switchSession(sessionID) }
        }
        Button("New Window", systemImage: "plus.rectangle") {
            model.runTmux(host: host) { try await $0.newWindow(inSession: sessionID) }
        }
    }
}

extension AppModel {
    /// Makes `host`'s terminal the visible one, then runs the tmux action; failures become notices.
    func runTmux(host: UUID, _ body: @escaping @MainActor (TmuxActions) async throws -> Void) {
        selection = host
        guard let actions = sessions.existingController(for: host)?.tmuxActions else { return }
        Task { await actions.run { try await body(actions) } }
    }

    /// Selects `host`, then asks for a confirmed kill (the dialog lives on the terminal screen).
    func requestKill(host: UUID, _ ask: @MainActor (TmuxActions) -> Void) {
        selection = host
        if let actions = sessions.existingController(for: host)?.tmuxActions { ask(actions) }
    }
}

/// A pending window rename (the alert's target).
struct WindowRenaming: Identifiable {
    let host: UUID
    let windowID: String
    var id: String { windowID }
}

extension View {
    /// The "Rename Window" alert shared by sidebar rows and window tabs; the owner sets `renaming`
    /// and `newName` (the current name) from the menu's rename action.
    func windowRenameAlert(renaming: Binding<WindowRenaming?>, newName: Binding<String>) -> some View {
        modifier(WindowRenameAlert(renaming: renaming, newName: newName))
    }
}

private struct WindowRenameAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var renaming: WindowRenaming?
    @Binding var newName: String

    func body(content: Content) -> some View {
        content.alert("Rename Window", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).accessibilityIdentifier("rename-window-field")
            Button("Rename") {
                if let r = renaming {
                    let name = newName
                    model.runTmux(host: r.host) { try await $0.renameWindow(r.windowID, to: name) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

/// Window strip above the terminal (shown while the sidebar is collapsed): a session menu, one tab
/// per window of the viewed session and a new-window button. Targets are at least 44 pt and the
/// strip grows with Dynamic Type.
struct WindowTabStrip: View {
    @Environment(AppModel.self) private var model
    let host: HostProfile
    let controller: SessionController
    /// Full screen's handle, docked at the trailing end while the strip is shown.
    var handle: FullScreenHandle?
    @State private var renaming: WindowRenaming?
    @State private var newName = ""
    @ScaledMetric(relativeTo: .body) private var minTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var hPadding: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 4

    var body: some View {
        let actions = controller.tmuxActions
        if let topology = controller.tmux.topology, let session = actions.viewedSession {
            let strip = TabStripModel(topology: topology, viewedSessionID: session.id, host: host.id, badges: model.badges)
            HStack(spacing: 0) {
                sessionMenu(strip)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(strip.tabs) { tab in tabButton(tab, actions: actions, sessionID: session.id) }
                    }
                    .padding(.horizontal, spacing * 2)
                }
                Button { Task { await actions.run { try await actions.newWindow() } } } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: minTarget, minHeight: minTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New Window")
                .accessibilityIdentifier("window-tab-new")
                handle
            }
            .background(.chromeElevated)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("window-tab-strip")
            .windowRenameAlert(renaming: $renaming, newName: $newName)
        }
    }

    private func sessionMenu(_ strip: TabStripModel) -> some View {
        Menu {
            ForEach(strip.sessions) { entry in
                Button {
                    model.runTmux(host: host.id) { try await $0.switchSession(entry.id) }
                } label: {
                    if entry.isViewed {
                        Label(entry.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: entry.name)
                    }
                }
            }
            Divider()
            if let id = strip.viewedSessionID {
                Button("New Window", systemImage: "plus.rectangle") {
                    model.runTmux(host: host.id) { try await $0.newWindow(inSession: id) }
                }
            }
        } label: {
            Image(systemName: "rectangle.stack")
                .frame(minWidth: minTarget, minHeight: minTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Session: \(strip.viewedSessionName ?? "")")
        .accessibilityIdentifier("window-tab-session-menu")
    }

    private func tabButton(_ tab: TabStripModel.Tab, actions: TmuxActions, sessionID: String) -> some View {
        let w = tab.row
        return Button { Task { await actions.run { try await actions.selectWindow(w.id) } } } label: {
            HStack(spacing: spacing) {
                Text(w.title).lineLimit(1)
                if w.zoomed { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2) }
                BadgeView(badge: w.badge)
            }
            .font(.subheadline.weight(w.active ? .semibold : .regular))
            .padding(.horizontal, hPadding)
            .frame(minHeight: minTarget)
            .background(w.active ? Color.accentColor.opacity(0.25) : Color.clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            TmuxWindowMenu(host: host.id, sessionID: sessionID, window: w) {
                newName = w.name
                renaming = WindowRenaming(host: host.id, windowID: w.id)
            }
        }
        .accessibilityLabel(tab.label)
        .accessibilityIdentifier("window-tab-\(w.id)")
        .accessibilityValue(tab.value)
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
                .foregroundStyle(.chromeSecondary)
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
                .chromeForm()
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
            Image(systemName: icon(item.kind)).frame(width: 22).foregroundStyle(.chromeSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.chromeSecondary).lineLimit(1)
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
