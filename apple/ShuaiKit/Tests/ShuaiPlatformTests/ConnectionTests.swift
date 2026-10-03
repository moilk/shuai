#if SHUAI_TESTKIT
import Foundation
import Testing
import ShuaiCore
@testable import ShuaiPlatform

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shuai-tests-\(UUID().uuidString)")
        .appendingPathComponent("known_hosts")
}

private func config(_ s: TestServer, password: String? = nil) -> FfiConnectConfig {
    FfiConnectConfig(
        host: "127.0.0.1", port: s.port(), username: s.username(),
        auth: [.password(password: password ?? s.password())],
        keepaliveSecs: 15, connectTimeoutSecs: 5, authTimeoutSecs: 10)
}

private func collect(_ shell: Shell, until needle: String) async throws -> String {
    var acc = Data()
    for try await ev in shell.events {
        if case .data(let bytes) = ev { acc.append(bytes) }
        let s = String(decoding: acc, as: UTF8.self)
        if s.contains(needle) { return s }
        if case .closed = ev { break }
    }
    return String(decoding: acc, as: UTF8.self)
}

@Suite(.timeLimit(.minutes(1))) struct ConnectionTests {
    @Test func shellRoundTripWithCJK() async throws {
        let server = await startTestSshServer()
        let store = KnownHostsStore(fileURL: tempFile())
        let conn = try await Connection.connect(
            config: config(server),
            verifier: TOFUVerifier(store: store) { _ in true })
        let shell = try await conn.openShell(cols: 80, rows: 24)
        try await shell.write(Data("echo 中文\n".utf8))
        let out = try await collect(shell, until: "中文")
        #expect(out.contains("echo 中文"))
        try await shell.resize(cols: 100, rows: 30)
        #expect(try await collect(shell, until: "RESIZE 100 30").contains("RESIZE 100 30"))
        await conn.disconnect()
        #expect(await conn.closed() == .local)
    }

    @Test func hostKeyIsRememberedAfterFirstConnect() async throws {
        let server = await startTestSshServer()
        let store = KnownHostsStore(fileURL: tempFile())
        let asked = Box()
        let verifier = TOFUVerifier(store: store) { _ in asked.bump(); return true }
        let c1 = try await Connection.connect(config: config(server), verifier: verifier)
        await c1.disconnect()
        let c2 = try await Connection.connect(config: config(server), verifier: verifier)
        await c2.disconnect()
        #expect(asked.count == 1)
        #expect(try store.check(host: "127.0.0.1", port: server.port(), publicKeyLine: server.hostPublicKeyLine()) == .trusted)
    }

    @Test func rejectedHostKeyFailsConnect() async throws {
        let server = await startTestSshServer()
        let verifier = TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { _ in false }
        await #expect(throws: FfiSshError.HostKeyRejected) {
            _ = try await Connection.connect(config: config(server), verifier: verifier)
        }
    }

    @Test func wrongPasswordFails() async throws {
        let server = await startTestSshServer()
        let verifier = TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { _ in true }
        await #expect(throws: FfiSshError.AuthFailed(triedMethods: ["password"])) {
            _ = try await Connection.connect(config: config(server, password: "bad"), verifier: verifier)
        }
    }

    @Test func execAndUpload() async throws {
        let server = await startTestSshServer()
        let conn = try await Connection.connect(
            config: config(server), verifier: TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { _ in true })
        let r = try await conn.exec("ok")
        #expect(String(decoding: r.stdout, as: UTF8.self) == "fine\n")
        #expect(r.exitStatus == 0)
        try await conn.upload(Data(repeating: 7, count: 100_000), to: "/tmp/shuai-agent", mode: 0o755)
        await conn.disconnect()
    }

    @Test func execStreamDeliversEventsInOrder() async throws {
        let server = await startTestSshServer()
        let conn = try await Connection.connect(
            config: config(server), verifier: TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { _ in true })
        let stream = try await conn.execStream("stream")
        var out = ""
        var closed = false
        for try await ev in stream.events {
            switch ev {
            case .stdout(let b): out += String(decoding: b, as: UTF8.self)
            case .closed: closed = true
            default: break
            }
        }
        #expect(out == "line 0\nline 1\nline 2\n")
        #expect(closed)
    }

    @Test func shellEventsFinishAfterClose() async throws {
        let server = await startTestSshServer()
        let conn = try await Connection.connect(
            config: config(server), verifier: TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { _ in true })
        let shell = try await conn.openShell(cols: 80, rows: 24)
        try await shell.write(Data("EXIT3".utf8))
        var exit: UInt32?
        for try await ev in shell.events {
            if case .exit(let status, _) = ev { exit = status }
        }
        #expect(exit == 3)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
#endif
