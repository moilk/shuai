import Foundation
import Testing
@testable import ShuaiApp

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shuai-app-tests-\(UUID().uuidString)")
        .appendingPathComponent("hosts.json")
}

private func sample(_ name: String = "dev", auth: HostAuth = .ask) -> HostProfile {
    HostProfile(name: name, host: "dev.example.com", username: "alice", auth: auth)
}

@MainActor @Suite struct HostProfileTests {
    @Test func defaults() {
        let p = sample()
        #expect(p.port == 22)
        #expect(p.tmux == TmuxPrefs(enabled: true, sessionName: "shuai"))
        #expect(p.startupCommand == nil)
        #expect(p.lastConnectedAt == nil)
    }

    @Test func validProfileHasNoErrors() {
        #expect(sample().validationErrors.isEmpty)
    }

    @Test func validationFlagsEachField() {
        var p = sample()
        p.name = "  "
        p.host = "has space"
        p.port = 70000
        p.username = ""
        p.auth = .key(keyID: "")
        p.tmux.sessionName = "a:b"
        #expect(Set(p.validationErrors) == [.name, .host, .port, .username, .key, .tmuxSessionName])
    }

    @Test func tmuxSessionNameIgnoredWhenTmuxDisabled() {
        var p = sample()
        p.tmux = TmuxPrefs(enabled: false, sessionName: "")
        #expect(p.validationErrors.isEmpty)
    }

    @Test func authCodableRoundTripsEveryCase() throws {
        for auth in [HostAuth.key(keyID: "k1"), .password, .ask] {
            let data = try JSONEncoder().encode(auth)
            #expect(try JSONDecoder().decode(HostAuth.self, from: data) == auth)
        }
    }

    @Test func displayTargetOmitsDefaultPort() {
        var p = sample()
        #expect(p.displayTarget == "alice@dev.example.com")
        p.port = 2222
        #expect(p.displayTarget == "alice@dev.example.com:2222")
    }
}

@MainActor @Suite struct HostStoreTests {
    @Test func startsEmptyWhenNoFile() {
        #expect(HostStore(fileURL: tempURL()).hosts.isEmpty)
    }

    @Test func roundTripsThroughDisk() throws {
        let url = tempURL()
        let a = HostStore(fileURL: url)
        var p = sample("one", auth: .key(keyID: "k"))
        p.startupCommand = "claude"
        p.tmux = TmuxPrefs(enabled: false, sessionName: "x")
        try a.add(p)
        try a.add(sample("two", auth: .password))
        let b = HostStore(fileURL: url)
        #expect(b.hosts.map(\.name) == ["one", "two"])
        #expect(b.hosts[0] == p)
    }

    @Test func updateAndDelete() throws {
        let store = HostStore(fileURL: tempURL())
        var p = sample()
        try store.add(p)
        p.name = "renamed"
        try store.update(p)
        #expect(store.hosts.map(\.name) == ["renamed"])
        try store.delete(id: p.id)
        #expect(store.hosts.isEmpty)
        #expect(HostStore(fileURL: store.fileURL).hosts.isEmpty)
    }

    @Test func markConnectedPersistsTimestamp() throws {
        let url = tempURL()
        let store = HostStore(fileURL: url)
        let p = sample()
        try store.add(p)
        try store.markConnected(id: p.id, at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(HostStore(fileURL: url).hosts[0].lastConnectedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func writesSchemaVersionAtomically() throws {
        let url = tempURL()
        let store = HostStore(fileURL: url)
        try store.add(sample())
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == HostStore.currentVersion)
        #expect((json?["hosts"] as? [Any])?.count == 1)
        // No temp files left behind by the atomic write.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == ["hosts.json"])
    }

    @Test func migratesLegacyBareArray() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
        [{"id":"6F1F4E7C-8A55-4C54-9A0B-1A2B3C4D5E6F","name":"old","host":"h","username":"u"}]
        """
        try Data(legacy.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        #expect(store.hosts.map(\.name) == ["old"])
        #expect(store.hosts[0].port == 22)
        #expect(store.hosts[0].auth == .ask)
        #expect(store.hosts[0].tmux.enabled)
        #expect(store.loadError == nil)
        // Rewritten in the current schema.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(json?["version"] as? Int == HostStore.currentVersion)
    }

    @Test func refusesToClobberANewerSchema() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = #"{"version":999,"hosts":[],"extra":true}"#
        try Data(future.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        #expect(store.loadError == .newerSchema(999))
        #expect(throws: HostStoreError.self) { try store.add(sample()) }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == future)
    }

    @Test func corruptFileSurfacesErrorAndKeepsBackup() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = HostStore(fileURL: url)
        #expect(store.hosts.isEmpty)
        #expect(store.loadError == .corrupt)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("hosts.json.corrupt") })
        // The store is usable again afterwards.
        try store.add(sample())
        #expect(HostStore(fileURL: url).hosts.count == 1)
    }
}
