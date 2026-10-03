import Foundation
import Testing
import ShuaiPlatform
@testable import ShuaiApp

@MainActor @Suite struct SessionRegistryTests {
    private func make() -> (SessionRegistry, HostStore, FakeFactory) {
        let hosts = HostStore(fileURL: scratchURL("hosts.json"))
        let factory = FakeFactory()
        let registry = SessionRegistry(
            factory: factory, keys: InMemoryKeyStore(), passwords: InMemoryPasswordStore(),
            knownHosts: KnownHostsStore(fileURL: scratchURL("known_hosts")), hosts: hosts,
            makeEngine: { _ in FakeEngine() })
        return (registry, hosts, factory)
    }

    private func profile(_ name: String = "dev") -> HostProfile {
        HostProfile(name: name, host: "h", username: "u", auth: .password)
    }

    @Test func controllersAreCachedPerHost() {
        let (r, _, _) = make()
        let p = profile()
        #expect(r.controller(for: p) === r.controller(for: p))
        #expect(r.controller(for: p) !== r.controller(for: profile("other")))
    }

    @Test func statusIsOffUntilAConnectionExists() async {
        let (r, _, _) = make()
        let p = profile()
        #expect(r.status(for: p.id) == .off)
        _ = r.controller(for: p)
        #expect(r.status(for: p.id) == .off)
    }

    @Test func editedProfileReplacesAnIdleController() {
        let (r, _, _) = make()
        var p = profile()
        let old = r.controller(for: p)
        p.name = "renamed"
        let new = r.controller(for: p)
        #expect(new !== old)
        #expect(new.profile.name == "renamed")
    }

    @Test func connectingMarksLastConnectedInTheHostStore() async throws {
        let (r, hosts, _) = make()
        let p = profile()
        try hosts.add(p)
        try? InMemoryPasswordStore().setPassword("x", for: p.id)
        let c = r.controller(for: p)
        c.onConnected?()
        #expect(hosts.host(id: p.id)?.lastConnectedAt != nil)
    }

    @Test func removeDisconnectsAndForgets() async {
        let (r, _, _) = make()
        let p = profile()
        let c = r.controller(for: p)
        await r.remove(id: p.id)
        #expect(r.controller(for: p) !== c)
    }

    @Test func switcherSnapshotsListEveryHostWithItsTreeAndConnectedFlag() async {
        let (r, _, _) = make()
        let a = profile("a"), b = profile("b")
        _ = r.controller(for: a)
        let snaps = r.switcherSnapshots(for: [a, b])
        #expect(snaps.map(\.name) == ["a", "b"])
        #expect(snaps.allSatisfy { !$0.connected && $0.topology == nil })
        #expect(snaps.map(\.id) == [a.id, b.id])
    }
}
