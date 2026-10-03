import Foundation
import ShuaiCore
import ShuaiPlatform
import ShuaiTerminal
@testable import ShuaiApp

/// Records everything a `SessionController` does to its terminal.
@MainActor
final class FakeEngine: TerminalEngine {
    var fed: [Data] = []
    var gridSize = TerminalGridSize(cols: 100, rows: 30)
    var title = ""
    var resizeCalls = 0
    var onInput: ((Data) -> Void)?
    var onResize: ((TerminalGridSize) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onNotification: ((TerminalNotification) -> Void)?
    var onClipboardRequest: ((ClipboardRequest) -> Void)?
    var onHyperlink: ((URL) -> Void)?
    var isMouseReportingEnabled: Bool { false }

    func feed(_ data: Data) { fed.append(data) }
    func resize(cols: Int, rows: Int) { resizeCalls += 1 }
    func sendKey(_ stroke: KeyStroke) {}
    func paste(_ text: String) {}
    func readScreenText() -> String? { nil }

    var fedText: String { String(decoding: fed.reduce(Data(), +), as: UTF8.self) }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
    var get: T { with { $0 } }
}

final class FakeShell: RemoteShell, @unchecked Sendable {
    let events: AsyncStream<ShellEvent>
    private let continuation: AsyncStream<ShellEvent>.Continuation
    let writes = Locked<[Data]>([])
    let resizes = Locked<[TerminalGridSize]>([])
    let closeCalls = Locked(0)

    init() { (events, continuation) = AsyncStream.makeStream() }

    func emit(_ text: String) { continuation.yield(.data(bytes: Data(text.utf8))) }
    func emit(_ event: ShellEvent) { continuation.yield(event) }
    func write(_ data: Data) async throws { writes.with { $0.append(data) } }
    func resize(cols: UInt32, rows: UInt32) async throws {
        resizes.with { $0.append(TerminalGridSize(cols: Int(cols), rows: Int(rows))) }
    }
    func close() async { closeCalls.with { $0 += 1 }; continuation.finish() }

    var writtenText: String { String(decoding: writes.get.reduce(Data(), +), as: UTF8.self) }
}

final class FakeExec: RemoteExec, @unchecked Sendable {
    let events: AsyncStream<ExecEvent>
    private let continuation: AsyncStream<ExecEvent>.Continuation
    let stdin = Locked<[String]>([])
    let closeCalls = Locked(0)
    /// Called synchronously with every chunk written to stdin.
    let onWrite = Locked<(@Sendable (String) -> Void)?>(nil)

    init() { (events, continuation) = AsyncStream.makeStream() }

    func emit(_ text: String) { continuation.yield(.stdout(bytes: Data(text.utf8))) }
    func emit(_ event: ExecEvent) { continuation.yield(event) }
    func finish(_ reason: CloseReason = .remote) {
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }
    func writeStdin(_ data: Data) async throws {
        let s = String(decoding: data, as: UTF8.self)
        stdin.with { $0.append(s) }
        onWrite.get?(s)
    }
    func close() async { closeCalls.with { $0 += 1 }; continuation.finish() }

    /// Every stdin line written so far.
    var lines: [String] { stdin.get.joined().split(separator: "\n").map(String.init) }
}

/// Plays the tmux side of a control-mode channel: answers every command line with a
/// `%begin/%end` block (list-panes/list-clients/display-message with canned data, anything
/// else echoed back as `reply:<line>`, `bogus*` as `%error`).
final class FakeControlServer: @unchecked Sendable {
    let panes: Locked<String>
    let clients = Locked<String>("")
    let controlPid = Locked(4242)
    let commands = Locked<[String]>([])
    private let seq = Locked(0)

    init(panes: String) { self.panes = Locked(panes) }

    var listPanesCount: Int { commands.get.filter { $0.hasPrefix("list-panes") }.count }

    func install(on exec: FakeExec) {
        exec.onWrite.with { $0 = { [unowned self, unowned exec] chunk in
            for line in chunk.split(separator: "\n").map(String.init) { respond(line, exec) }
        } }
    }

    func respond(_ line: String, _ exec: FakeExec) {
        commands.with { $0.append(line) }
        let n = seq.with { $0 += 1; return $0 }
        let name = line.split(separator: " ").first.map(String.init) ?? ""
        var body = ""
        var ok = true
        switch name {
        case "list-panes": body = panes.get
        case "list-clients": body = clients.get
        case "display-message": body = "\(controlPid.get)\n"
        case let n where n.hasPrefix("bogus"):
            ok = false
            body = "parse error: unknown command: \(n)\n"
        default: body = "reply:\(line)\n"
        }
        exec.emit("%begin 1791017745 \(n) 1\n\(body)%\(ok ? "end" : "error") 1791017745 \(n) 1\n")
    }
}

enum Fixtures {
    /// `core/shuai-tmux/tests/fixtures/NAME` (real tmux 3.6 transcripts; only the sanitized `local36-*` ones).
    static func text(_ name: String, file: StaticString = #filePath) -> String {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0 ..< 4 { url.deleteLastPathComponent() }
        url.appendPathComponent("core/shuai-tmux/tests/fixtures/\(name)")
        return try! String(contentsOf: url, encoding: .utf8)
    }
}

enum ShellOpen: Equatable {
    case shell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar])
    case ptyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar])
}

final class FakeConnection: RemoteConnection, @unchecked Sendable {
    private let shells = Locked<[FakeShell]>([FakeShell()])
    private let handedOut = Locked(0)
    /// The most recently opened shell (the pre-made first one before anything was opened).
    var shell: FakeShell { shells.get.last! }
    let opens = Locked<[ShellOpen]>([])
    let disconnects = Locked(0)
    private let closedState = Locked<(reason: CloseReason?, waiters: [CheckedContinuation<CloseReason, Never>])>((nil, []))
    var openError: Error?

    // exec / exec streams
    let execCommands = Locked<[String]>([])
    let execStreamCommands = Locked<[String]>([])
    let execStreams = Locked<[FakeExec]>([])
    /// Result of one-shot `exec` (default: command not found, like a host without tmux).
    let execHandler = Locked<@Sendable (String) -> ExecResult>({ _ in
        ExecResult(stdout: Data(), stderr: Data("sh: tmux: not found".utf8), exitStatus: 127, exitSignal: nil)
    })
    /// Runs for every opened exec stream (1-based count) before it is returned.
    let execStreamSetup = Locked<(@Sendable (FakeExec, Int) -> Void)?>(nil)
    var execStreamError: Error?

    func exec(_ command: String) async throws -> ExecResult {
        execCommands.with { $0.append(command) }
        return execHandler.get(command)
    }

    func execStream(_ command: String) async throws -> RemoteExec {
        if let execStreamError { throw execStreamError }
        execStreamCommands.with { $0.append(command) }
        let stream = FakeExec()
        let n = execStreams.with { $0.append(stream); return $0.count }
        execStreamSetup.get?(stream, n)
        return stream
    }

    func openShell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        if let openError { throw openError }
        opens.with { $0.append(.shell(cols: cols, rows: rows, term: term, env: env)) }
        return nextShell()
    }

    /// The first open gets the pre-made shell; later opens (fallbacks) get fresh ones.
    private func nextShell() -> FakeShell {
        let n = handedOut.with { $0 += 1; return $0 }
        if n == 1 { return shells.get[0] }
        let s = FakeShell()
        shells.with { $0.append(s) }
        return s
    }

    func openPtyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        if let openError { throw openError }
        opens.with { $0.append(.ptyExec(command: command, cols: cols, rows: rows, term: term, env: env)) }
        return nextShell()
    }

    func closed() async -> CloseReason {
        await withCheckedContinuation { cont in
            let ready: CloseReason? = closedState.with { s in
                if let r = s.reason { return r }
                s.waiters.append(cont)
                return nil
            }
            if let ready { cont.resume(returning: ready) }
        }
    }

    func disconnect() async {
        disconnects.with { $0 += 1 }
        end(.local)
    }

    /// Simulates the session ending.
    func end(_ reason: CloseReason) {
        let waiters = closedState.with { s -> [CheckedContinuation<CloseReason, Never>] in
            guard s.reason == nil else { return [] }
            s.reason = reason
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume(returning: reason) }
    }
}

/// Scripted factory: `script` runs per connect attempt (attempt number from 1) and may call the
/// verifier / kbd prompter like the real SSH layer would.
final class FakeFactory: ConnectionFactory, @unchecked Sendable {
    typealias Script = @Sendable (_ attempt: Int, _ config: FfiConnectConfig, _ verifier: HostKeyVerifierCallback, _ conn: FakeConnection) async throws -> Void

    let configs = Locked<[FfiConnectConfig]>([])
    let connections = Locked<[FakeConnection]>([])
    private let script: Script

    init(script: @escaping Script = { _, _, _, _ in }) { self.script = script }

    var attempts: Int { configs.get.count }
    var last: FakeConnection? { connections.get.last }

    func connect(config: FfiConnectConfig, verifier: HostKeyVerifierCallback) async throws -> RemoteConnection {
        let conn = FakeConnection()
        let n = configs.with { $0.append(config); return $0.count }
        connections.with { $0.append(conn) }
        try await script(n, config, verifier, conn)
        return conn
    }
}

/// Polls on the main actor until `condition` holds.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func scratchURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shuai-app-tests-\(UUID().uuidString)")
        .appendingPathComponent(name)
}
