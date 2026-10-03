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

enum ShellOpen: Equatable {
    case shell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar])
    case ptyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar])
}

final class FakeConnection: RemoteConnection, @unchecked Sendable {
    let shell = FakeShell()
    let opens = Locked<[ShellOpen]>([])
    let disconnects = Locked(0)
    private let closedState = Locked<(reason: CloseReason?, waiters: [CheckedContinuation<CloseReason, Never>])>((nil, []))
    var openError: Error?

    func openShell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        if let openError { throw openError }
        opens.with { $0.append(.shell(cols: cols, rows: rows, term: term, env: env)) }
        return shell
    }

    func openPtyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        if let openError { throw openError }
        opens.with { $0.append(.ptyExec(command: command, cols: cols, rows: rows, term: term, env: env)) }
        return shell
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
