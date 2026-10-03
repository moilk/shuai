import Foundation
import Observation
import ShuaiPlatform
import ShuaiTerminal

/// Owns one `SessionController` (and its terminal engine) per host so sessions survive
/// sidebar navigation, and exposes status dots for the host list.
@MainActor @Observable
public final class SessionRegistry {
    private var controllers: [UUID: SessionController] = [:]
    @ObservationIgnored private let factory: ConnectionFactory
    @ObservationIgnored private let keys: KeyStore
    @ObservationIgnored private let passwords: PasswordStore
    @ObservationIgnored private let knownHosts: KnownHostsStore
    @ObservationIgnored private let hosts: HostStore
    @ObservationIgnored private let makeEngine: @MainActor (HostProfile) -> any TerminalEngine

    public init(
        factory: ConnectionFactory, keys: KeyStore, passwords: PasswordStore, knownHosts: KnownHostsStore,
        hosts: HostStore, makeEngine: @escaping @MainActor (HostProfile) -> any TerminalEngine
    ) {
        self.factory = factory
        self.keys = keys
        self.passwords = passwords
        self.knownHosts = knownHosts
        self.hosts = hosts
        self.makeEngine = makeEngine
    }

    /// The (cached) controller for `host`. A profile edited while its session is not live gets a
    /// fresh controller; a live session keeps running with its original settings.
    public func controller(for host: HostProfile) -> SessionController {
        if let existing = controllers[host.id] {
            if existing.profile == host { return existing }
            switch existing.state {
            case .idle, .disconnected, .failed: break
            default: return existing
            }
        }
        let engine = makeEngine(host)
        let controller = SessionController(
            profile: host, engine: engine, factory: factory, keys: keys, passwords: passwords, knownHosts: knownHosts)
        let id = host.id
        controller.onConnected = { [weak hosts] in try? hosts?.markConnected(id: id) }
        controllers[host.id] = controller
        return controller
    }

    public func existingController(for id: UUID) -> SessionController? { controllers[id] }

    public func status(for id: UUID) -> SessionState.Status {
        controllers[id]?.state.status ?? .off
    }

    /// Every host with its live tmux tree, as input for `SwitcherItem.build`.
    public func switcherSnapshots(for hosts: [HostProfile]) -> [SwitcherItem.HostSnapshot] {
        hosts.map { h in
            let c = controllers[h.id]
            return SwitcherItem.HostSnapshot(
                id: h.id, name: h.name, connected: c?.state == .connected, topology: c?.tmux.topology)
        }
    }

    public func remove(id: UUID) async {
        guard let c = controllers.removeValue(forKey: id) else { return }
        await c.disconnect()
    }

    public func networkChanged() { controllers.values.forEach { $0.networkChanged() } }
    public func appForegrounded() { controllers.values.forEach { $0.appForegrounded() } }
}
