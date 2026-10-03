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
