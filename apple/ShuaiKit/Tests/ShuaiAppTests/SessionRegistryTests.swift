import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal
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

    @Test func controllersPostToTheRegistryNotices() {
        let sink = RecordingNoticeSink()
        let engine = FakeEngine()
        let registry = SessionRegistry(
            factory: FakeFactory(), keys: InMemoryKeyStore(), passwords: InMemoryPasswordStore(),
            knownHosts: KnownHostsStore(fileURL: scratchURL("known_hosts")),
            hosts: HostStore(fileURL: scratchURL("hosts.json")), makeEngine: { _ in engine }, notices: sink)
        let p = profile()
        _ = registry.controller(for: p)
        engine.onNotification?(TerminalNotification(title: "t", body: "b"))
        #expect(sink.posted.last?.scope == .host(p.id))
    }

    @Test func removingAHostRetractsItsNoticesAndSilencesTheController() async {
        let sink = RecordingNoticeSink()
        let engine = FakeEngine()
        let registry = SessionRegistry(
            factory: FakeFactory(), keys: InMemoryKeyStore(), passwords: InMemoryPasswordStore(),
            knownHosts: KnownHostsStore(fileURL: scratchURL("known_hosts")),
            hosts: HostStore(fileURL: scratchURL("hosts.json")), makeEngine: { _ in engine }, notices: sink)
        let p = profile()
        _ = registry.controller(for: p)
        await registry.remove(id: p.id)
        let id = p.id.uuidString
        #expect(["tmux-missing:\(id)", "osc:\(id)", "tmux-error:\(id)"].allSatisfy(sink.retractedKeys.contains))
        let before = sink.events.count
        engine.onNotification?(TerminalNotification(title: "t", body: "b"))
        #expect(sink.events.count == before)
    }

    @Test func replacingAControllerRetractsTheOldOnesNotices() {
        let sink = RecordingNoticeSink()
        let registry = SessionRegistry(
            factory: FakeFactory(), keys: InMemoryKeyStore(), passwords: InMemoryPasswordStore(),
            knownHosts: KnownHostsStore(fileURL: scratchURL("known_hosts")),
            hosts: HostStore(fileURL: scratchURL("hosts.json")), makeEngine: { _ in FakeEngine() }, notices: sink)
        var p = profile()
        let old = registry.controller(for: p)
        p.name = "renamed"
        let new = registry.controller(for: p)
        #expect(old !== new)
        #expect(sink.retractedKeys.contains("tmux-missing:\(p.id.uuidString)"))
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

    @Test func connectedHostsAreHandedToTheAgentHubAndForgottenOnRemove() async throws {
        let hosts = HostStore(fileURL: scratchURL("hosts.json"))
        let key = try! generateKey(alg: .ed25519, comment: "").publicLine
        let factory = FakeFactory { _, _, v, conn in
            _ = await v.verify(host: "h", port: 22, publicKeyLine: key)
            conn.execHandler.with { $0 = { cmd in
                let out = cmd.contains("--version") ? "host=reg-host\nagent=shuai-agent 0.1.0\n" : ""
                return ExecResult(stdout: Data(out.utf8), stderr: Data(), exitStatus: 0, exitSignal: nil)
            } }
        }
        let known = KnownHostsStore(fileURL: scratchURL("known_hosts"))
        try known.add(host: "h", port: 22, publicKeyLine: key)
        let hub = AgentHub(expectedVersion: "0.1.0")
        let registry = SessionRegistry(
            factory: factory, keys: InMemoryKeyStore(), passwords: InMemoryPasswordStore(), knownHosts: known,
            hosts: hosts, makeEngine: { _ in FakeEngine() }, agentHub: hub)
        var p = profile()
        p.tmux.enabled = false
        try hosts.add(p)
        let c = registry.controller(for: p)
        await c.connect()
        #expect(c.state == .connected)
        #expect(await waitUntil { hub.monitor(for: p.id)?.host == "reg-host" })
        #expect(hub.status(for: p.id) == .installed(version: "0.1.0"))
        await c.disconnect()
        #expect(await waitUntil { hub.monitor(for: p.id)?.state == .disconnected })
        await registry.remove(id: p.id)
        #expect(hub.monitor(for: p.id) == nil)
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
