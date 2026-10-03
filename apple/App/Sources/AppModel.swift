import Foundation
import Network
import Observation
import ShuaiApp
import ShuaiPlatform
import ShuaiTerminal
import SwiftUI

enum HostEditorTarget: Identifiable {
    case new
    case edit(HostProfile)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let h): h.id.uuidString
        }
    }
}

/// Composition root: owns the stores and the session registry. Views stay thin.
@MainActor @Observable
final class AppModel {
    let hosts: HostStore
    let keys: KeyLibrary
    let settings: AppSettings
    let passwords: PasswordStore
    let sessions: SessionRegistry
    let keyboard = HardwareKeyboardMonitor()

    var selection: UUID?
    var editor: HostEditorTarget?
    var showSettings = false
    var showKeys = false
    /// Sidebar visibility (the window tab strip shows while the sidebar is collapsed).
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// Hardware shortcuts delivered while the terminal has focus.
    var shortcuts: ShortcutMap = .defaults
    /// Per-pane badges (agent state in M5); none for now.
    var badges: any PaneBadgeProvider = NoPaneBadges()
    /// The open ⌘K sheet, if any.
    var quickSwitcher: QuickSwitcherModel?
    @ObservationIgnored private var switcherHistory = QuickSwitcherHistory()

    @ObservationIgnored private(set) var engines: [UUID: GhosttyEngine] = [:]
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?

    /// - Parameter ephemeral: UI tests; temp files and in-memory secrets, nothing touches the user's data.
    init(ephemeral: Bool = false) {
        let settings: AppSettings
        let keyStore: KeyStore
        let known: KnownHostsStore
        if ephemeral {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shuai-ui-\(UUID().uuidString)")
            hosts = HostStore(fileURL: dir.appendingPathComponent("hosts.json"))
            keyStore = InMemoryKeyStore()
            passwords = InMemoryPasswordStore()
            known = KnownHostsStore(fileURL: dir.appendingPathComponent("known_hosts"))
            settings = AppSettings(defaults: UserDefaults(suiteName: "shuai-ui-\(UUID().uuidString)")!)
        } else {
            hosts = HostStore()
            keyStore = KeychainKeyStore()
            passwords = KeychainPasswordStore()
            known = KnownHostsStore()
            settings = AppSettings()
        }
        self.settings = settings
        keys = KeyLibrary(store: keyStore)
        let box = EngineBox()
        sessions = SessionRegistry(
            factory: LiveConnectionFactory(), keys: keyStore, passwords: passwords, knownHosts: known, hosts: hosts,
            makeEngine: { host in
                let engine = GhosttyEngine(
                    fontSize: Float(settings.fontSize), altSendsEscape: settings.optionAsAlt,
                    theme: settings.theme.terminalTheme)
                box.engines[host.id] = engine
                return engine
            })
        engineBox = box
        selection = hosts.hosts.first?.id
        startNetworkMonitor()
    }

    private final class EngineBox { var engines: [UUID: GhosttyEngine] = [:] }
    @ObservationIgnored private let engineBox: EngineBox

    func engine(for host: HostProfile) -> GhosttyEngine? {
        _ = sessions.controller(for: host)
        return engineBox.engines[host.id]
    }

    // MARK: tmux shortcuts and quick switcher

    /// A shortcut fired in `host`'s terminal.
    func handleShortcut(id: String, host: HostProfile) {
        guard let action = ShortcutAction(id: id) else { return }
        if action == .quickSwitcher { openQuickSwitcher(); return }
        let controller = sessions.controller(for: host)
        switch controller.tmux.state {
        case .live, .polling: break
        default: return // no tmux on this host / not connected: the key does nothing
        }
        let actions = controller.tmuxActions
        Task { await actions.run { try await actions.perform(action) } }
    }

    func openQuickSwitcher() {
        guard quickSwitcher == nil else { return }
        let items = SwitcherItem.build(hosts: sessions.switcherSnapshots(for: hosts.hosts))
        quickSwitcher = QuickSwitcherModel(items: items, badges: badges, history: switcherHistory)
    }

    func closeQuickSwitcher(activated: Bool) {
        if let q = quickSwitcher { switcherHistory = q.history }
        quickSwitcher = nil
    }

    /// Selects the item's host (connecting it if needed) and navigates its tmux there.
    func jump(to item: SwitcherItem) async {
        guard let host = hosts.host(id: item.hostID) else { return }
        selection = host.id
        let controller = sessions.controller(for: host)
        switch controller.state {
        case .idle, .failed, .disconnected: await controller.connect()
        default: break
        }
        if item.kind != .host {
            // A freshly connected host needs a moment until the control channel delivers its tree.
            _ = await waitForTmux(controller)
            let actions = controller.tmuxActions
            await actions.run { try await actions.jump(to: item) }
        }
        _ = engineBox.engines[host.id]?.view.acquireProgrammaticFocus()
    }

    private func waitForTmux(_ controller: SessionController) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            switch controller.tmux.state {
            case .live where controller.tmux.topology != nil: return true
            case .polling where controller.tmux.topology != nil: return true
            case .unavailable, .ended, .stopped: return false
            default: try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return false
    }

    func delete(_ host: HostProfile) {
        Task {
            await sessions.remove(id: host.id)
            engineBox.engines[host.id] = nil
            try? passwords.deletePassword(for: host.id)
            try? hosts.delete(id: host.id)
            if selection == host.id { selection = hosts.hosts.first?.id }
        }
    }

    func applyTheme() {
        for e in engineBox.engines.values { e.apply(theme: settings.theme.terminalTheme) }
    }

    // MARK: network / lifecycle

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-\(path.availableInterfaces.map(\.name))"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSignature = signature }
                // The first callback only reports the initial path.
                guard let last = self.lastPathSignature, last != signature, path.status == .satisfied else { return }
                self.sessions.networkChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "shuai.network"))
        pathMonitor = monitor
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active { sessions.appForegrounded() }
    }
}
