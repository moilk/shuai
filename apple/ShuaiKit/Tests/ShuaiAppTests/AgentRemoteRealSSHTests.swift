#if SHUAI_TESTKIT
import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform
@testable import ShuaiApp

/// `LiveAgentRemote` over the in-process testkit SSH server (real TCP + SSH).
@Suite(.timeLimit(.minutes(1))) struct AgentRemoteRealSSHTests {
    /// The server stops when its object is dropped, so it travels with the remote.
    private struct Harness { let server: TestServer; let remote: LiveAgentRemote }

    private func remote() async throws -> Harness {
        let server = await startTestSshServer()
        let store = KnownHostsStore(fileURL: scratchURL("known_hosts"))
        let conn = try await Connection.connect(
            config: FfiConnectConfig(
                host: "127.0.0.1", port: server.port(), username: server.username(),
                auth: [.password(password: server.password())],
                keepaliveSecs: 15, connectTimeoutSecs: 5, authTimeoutSecs: 10),
            verifier: TOFUVerifier(store: store) { _ in true })
        return Harness(server: server, remote: LiveAgentRemote(connection: conn))
    }

    @Test func execMapsStdoutStderrAndExitStatus() async throws {
        let h = try await remote()
        let r = h.remote
        defer { withExtendedLifetime(h.server) {} }
        #expect(try await r.exec("ok") == RemoteExecOutput(stdout: "fine\n", stderr: "", exitStatus: 0))
        let bad = try await r.exec("fail")
        #expect(bad.stdout == "partial out\n")
        #expect(bad.stderr == "some err\n")
        #expect(bad.exitStatus == 3)
        #expect(!bad.ok)
    }

    @Test func execStreamMapsEvents() async throws {
        let h = try await remote()
        let r = h.remote
        defer { withExtendedLifetime(h.server) {} }
        let s = try await r.execStream("stream")
        var out = ""
        var events: [AgentStreamEvent] = []
        for await e in s.events {
            events.append(e)
            if case .stdout(let b) = e { out += String(decoding: b, as: UTF8.self) }
        }
        #expect(out == "line 0\nline 1\nline 2\n")
        #expect(events.contains(.exited(0)))
        #expect(events.last == .closed)
    }

    @Test func signalExitHasNoStatus() async throws {
        let h = try await remote()
        let r = h.remote
        defer { withExtendedLifetime(h.server) {} }
        let out = try await r.exec("sig")
        #expect(out.exitStatus == nil)
    }

    @Test func uploadsAnAgentSizedBinary() async throws {
        let h = try await remote()
        let r = h.remote
        defer { withExtendedLifetime(h.server) {} }
        try await r.upload(Data(repeating: 1, count: 2 * 1024 * 1024), to: "/tmp/shuai-agent.new", mode: 0o755)
    }
}
#endif
