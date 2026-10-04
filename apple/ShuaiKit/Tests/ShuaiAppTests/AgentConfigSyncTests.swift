import Foundation
import Testing
@testable import ShuaiApp

private let hostileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let hostileName = "a\"b\\c\n\tü\u{7F}"

private func repoFile(_ rel: String) -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 5 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(rel)
}

@Suite("AgentConfigToml")
struct AgentConfigTomlTests {
    @Test func hostileValuesMatchTheGoldenFileTheAgentParses() throws {
        let toml = AgentConfigToml.render(
            hostID: hostileID, hostName: hostileName,
            ntfy: NtfyConfig(server: "https://ntfy.example.com", topic: "shuai-abc", token: "tk\"\\x"))
        let golden = try String(contentsOf: repoFile("fixtures/agent-config/hostile.toml"), encoding: .utf8)
        #expect(toml == golden)
    }

    @Test func withoutNtfyOnlyTheHostKeysAreWritten() {
        let toml = AgentConfigToml.render(hostID: hostileID, hostName: "mdev", ntfy: nil)
        #expect(toml.contains("host_id = \"11111111-2222-3333-4444-555555555555\"\n"))
        #expect(toml.contains("host_name = \"mdev\"\n"))
        #expect(!toml.contains("[ntfy]"))
    }

    @Test func tokenIsOmittedWhenThereIsNone() {
        let toml = AgentConfigToml.render(hostID: hostileID, hostName: "h", ntfy: NtfyConfig(server: "https://ntfy.sh", topic: "t", token: nil))
        #expect(!toml.contains("token"))
    }

    @Test func quoteEscapesEverythingDangerous() {
        #expect(AgentConfigToml.quote("plain") == "\"plain\"")
        #expect(AgentConfigToml.quote("a\"b") == "\"a\\\"b\"")
        #expect(AgentConfigToml.quote("a\\b") == "\"a\\\\b\"")
        #expect(AgentConfigToml.quote("x\"\nfoo = \"bar") == "\"x\\\"\\nfoo = \\\"bar\"")
        #expect(AgentConfigToml.quote("\u{0}\u{1B}\u{8}\u{C}\r") == "\"\\u0000\\u001B\\b\\f\\r\"")
        #expect(AgentConfigToml.quote("[ntfy]") == "\"[ntfy]\"")
    }

    @Test func newlineInjectionCannotAddKeys() {
        let toml = AgentConfigToml.render(hostID: hostileID, hostName: "x\"\n[ntfy]\ntopic = \"evil", ntfy: nil)
        #expect(toml.split(separator: "\n").count == 3, "comment + host_id + host_name, nothing injected")
    }
}

@Suite("AgentConfigWriter")
struct AgentConfigWriterTests {
    @Test func writesAtomicallyWithPrivateMode() async throws {
        let remote = FakeAgentRemote()
        try await AgentConfigWriter.write("toml-text", remote: remote, home: "/home/u")
        #expect(remote.uploads.get == [UploadRecord(path: "/home/u/.shuai/config.toml.tmp", data: Data("toml-text".utf8), mode: 0o600)])
        let cmds = remote.commands.get
        #expect(cmds.first == "mkdir -p /home/u/.shuai && chmod 700 /home/u/.shuai")
        #expect(cmds.last == "mv -f /home/u/.shuai/config.toml.tmp /home/u/.shuai/config.toml && chmod 600 /home/u/.shuai/config.toml")
    }

    /// The token must never sit in a world-readable file, not even for the instant between `cat >`
    /// creating the temp file and the `chmod`: it is pre-created 0600 under umask 077 (and any
    /// old file or symlink at that path removed first).
    @Test func tempFileExistsPrivateBeforeAnyContentIsUploaded() async throws {
        let remote = FakeAgentRemote()
        try await AgentConfigWriter.write("secret", remote: remote, home: "/home/u")
        let cmds = remote.commands.get
        #expect(cmds.count == 3)
        #expect(cmds[1] == "rm -f /home/u/.shuai/config.toml.tmp && (umask 077 && : > /home/u/.shuai/config.toml.tmp)")
        #expect(remote.uploads.get.count == 1)
    }

    @Test func windowNamesAreOffUnlessOptedIn() {
        let off = AgentConfigToml.render(hostID: hostileID, hostName: "h", ntfy: NtfyConfig(server: "https://ntfy.sh", topic: "t"))
        #expect(!off.contains("window_names"))
        let on = AgentConfigToml.render(
            hostID: hostileID, hostName: "h", ntfy: NtfyConfig(server: "https://ntfy.sh", topic: "t", includeWindowNames: true))
        #expect(on.contains("window_names = true\n"))
    }

    @Test func hostileHomeIsShellQuoted() async throws {
        let remote = FakeAgentRemote()
        try await AgentConfigWriter.write("x", remote: remote, home: "/home/o'b $(rm -rf ~)/`x`")
        for c in remote.commands.get {
            #expect(!c.contains("$(rm -rf ~)/") || c.contains("'/home/o'\\''b $(rm -rf ~)/`x`/.shuai"), "\(c)")
        }
        #expect(remote.commands.get[0] == "mkdir -p '/home/o'\\''b $(rm -rf ~)/`x`/.shuai' && chmod 700 '/home/o'\\''b $(rm -rf ~)/`x`/.shuai'")
        #expect(remote.commands.get.last == "mv -f '/home/o'\\''b $(rm -rf ~)/`x`/.shuai/config.toml.tmp' '/home/o'\\''b $(rm -rf ~)/`x`/.shuai/config.toml' && chmod 600 '/home/o'\\''b $(rm -rf ~)/`x`/.shuai/config.toml'")
    }

    @Test func failureSurfaces() async {
        let remote = FakeAgentRemote { cmd in cmd.hasPrefix("mv ") ? .fail(1, "Permission denied") : .ok() }
        await #expect(throws: AgentInstallError.self) {
            try await AgentConfigWriter.write("x", remote: remote, home: "/home/u")
        }
    }

    @Test func homeDiscovery() async throws {
        let ok = FakeAgentRemote { _ in .ok("/home/u") }
        #expect(try await AgentConfigWriter.discoverHome(remote: ok) == "/home/u")
        let bad = FakeAgentRemote { _ in .ok("relative") }
        await #expect(throws: AgentInstallError.self) { try await AgentConfigWriter.discoverHome(remote: bad) }
        let fail = FakeAgentRemote { _ in .fail(1, "") }
        await #expect(throws: AgentInstallError.self) { try await AgentConfigWriter.discoverHome(remote: fail) }
    }
}

@Suite("PushSyncCoordinator")
@MainActor
struct PushSyncCoordinatorTests {
    private func make() -> (PushSyncCoordinator, PushSettings, HostProfile) {
        let defaults = UserDefaults(suiteName: "sync-\(UUID().uuidString)")!
        let settings = PushSettings(defaults: defaults, secrets: InMemoryPushSecretStore(), transport: RecordingTransport())
        settings.enabled = true
        let host = HostProfile(name: "mdev", host: "h", username: "u")
        return (PushSyncCoordinator(settings: settings, defaults: defaults), settings, host)
    }

    private func remote() -> FakeAgentRemote { FakeAgentRemote { _ in .ok("/home/u") } }

    @Test func writesOnFirstConnectThenOnlyWhenSettingsChange() async {
        let (sync, settings, host) = make()
        let r = remote()
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .synced)
        #expect(r.uploads.get.count == 1)
        let text = String(decoding: r.uploads.get[0].data, as: UTF8.self)
        #expect(text.contains("host_id = \"\(host.id.uuidString)\""))
        #expect(text.contains("host_name = \"mdev\""))
        #expect(text.contains("topic = \"\(settings.topic)\""))
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .upToDate)
        #expect(r.uploads.get.count == 1)
        settings.serverText = "https://ntfy.example.com"
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .synced)
        #expect(r.uploads.get.count == 2)
        var renamed = host
        renamed.name = "other"
        #expect(await sync.syncIfNeeded(host: renamed, remote: r) == .synced)
    }

    @Test func disablingRemovesTheNtfySectionOnTheHost() async {
        let (sync, settings, host) = make()
        let r = remote()
        _ = await sync.syncIfNeeded(host: host, remote: r)
        settings.enabled = false
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .synced)
        #expect(!String(decoding: r.uploads.get[1].data, as: UTF8.self).contains("[ntfy]"))
    }

    @Test func aNewTopicIsWrittenOnTheNextSync() async {
        let (sync, settings, host) = make()
        let r = remote()
        _ = await sync.syncIfNeeded(host: host, remote: r)
        let old = settings.topic
        settings.regenerateTopic()
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .synced)
        let text = String(decoding: r.uploads.get[1].data, as: UTF8.self)
        #expect(text.contains("topic = \"\(settings.topic)\"") && !text.contains(old))
    }

    @Test func aFailedWriteIsRetriedNextTime() async {
        let (sync, _, host) = make()
        let bad = FakeAgentRemote { _ in .ok("/home/u") }
        bad.uploadError = URLError(.notConnectedToInternet)
        if case .failed = await sync.syncIfNeeded(host: host, remote: bad) {} else { Issue.record("expected failure") }
        let good = remote()
        #expect(await sync.syncIfNeeded(host: host, remote: good) == .synced)
    }

    @Test func manualSyncAlwaysWrites() async {
        let (sync, _, host) = make()
        let r = remote()
        _ = await sync.syncIfNeeded(host: host, remote: r)
        #expect(await sync.syncNow(host: host, remote: r) == .synced)
        #expect(r.uploads.get.count == 2)
    }

    @Test func installerRecordsWhatItWrote() async {
        let (sync, _, host) = make()
        let toml = sync.toml(for: host)
        sync.recordSynced(host: host, toml: toml)
        let r = remote()
        #expect(await sync.syncIfNeeded(host: host, remote: r) == .upToDate)
    }
}
