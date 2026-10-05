import Foundation
import ShuaiCore
import ShuaiPlatform

/// A PTY channel as the session controller sees it (real: `Shell`; tests: a fake).
public protocol RemoteShell: Sendable {
    /// Output events; finishes after `.closed`.
    var events: AsyncStream<ShellEvent> { get }
    func write(_ data: Data) async throws
    func resize(cols: UInt32, rows: UInt32) async throws
    func close() async
}

/// A non-PTY exec channel with streamed output (real: `ExecSession`; tests: a fake).
public protocol RemoteExec: Sendable {
    /// Output events; finishes after `.closed`.
    var events: AsyncStream<ExecEvent> { get }
    func writeStdin(_ data: Data) async throws
    /// Sends EOF on stdin (the channel stays open for output).
    func closeStdin() async
    func close() async
}

public protocol RemoteConnection: Sendable {
    func openShell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell
    /// Runs `command` directly on a PTY (no login shell, nothing typed).
    func openPtyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell
    /// Runs `command` to completion on a fresh channel.
    func exec(_ command: String) async throws -> ExecResult
    /// Starts `command` on a fresh channel without a PTY; stdin stays open for `writeStdin`.
    func execStream(_ command: String) async throws -> RemoteExec
    /// Writes `data` to `path` with `mode` (the agent installer).
    func upload(_ data: Data, to path: String, mode: UInt32) async throws
    /// Resolves when the session ends.
    func closed() async -> CloseReason
    func disconnect() async
}

extension RemoteConnection {
    /// Connections that cannot upload (local test doubles) fail the installer instead of silently doing nothing.
    public func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        throw AgentInstallError.commandFailed("This connection cannot upload files.")
    }
}

public protocol ConnectionFactory: Sendable {
    func connect(config: FfiConnectConfig, verifier: HostKeyVerifierCallback) async throws -> RemoteConnection
}

// MARK: - Live implementation over ShuaiPlatform

public struct LiveConnectionFactory: ConnectionFactory {
    public init() {}

    public func connect(config: FfiConnectConfig, verifier: HostKeyVerifierCallback) async throws -> RemoteConnection {
        LiveConnection(try await Connection.connect(config: config, verifier: verifier))
    }
}

final class LiveConnection: RemoteConnection {
    private let connection: Connection
    init(_ c: Connection) { connection = c }

    func openShell(cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        LiveShell(try await connection.openShell(cols: cols, rows: rows, term: term, env: env))
    }

    func openPtyExec(command: String, cols: UInt32, rows: UInt32, term: String, env: [FfiEnvVar]) async throws -> RemoteShell {
        LiveShell(try await connection.openPtyExec(command: command, cols: cols, rows: rows, term: term, env: env))
    }

    func exec(_ command: String) async throws -> ExecResult { try await connection.exec(command) }
    func execStream(_ command: String) async throws -> RemoteExec {
        LiveExec(try await connection.execStream(command))
    }

    func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        try await connection.upload(data, to: path, mode: mode)
    }

    func closed() async -> CloseReason { await connection.closed() }
    func disconnect() async { await connection.disconnect() }
}

final class LiveExec: RemoteExec {
    private let session: ExecSession
    let events: AsyncStream<ExecEvent>

    init(_ session: ExecSession) {
        self.session = session
        events = AsyncStream { continuation in
            let task = Task {
                for await event in session.events { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func writeStdin(_ data: Data) async throws { try await session.writeStdin(data) }
    func closeStdin() async { try? await session.eof() }
    func close() async { try? await session.close() }
}

final class LiveShell: RemoteShell {
    private let shell: Shell
    let events: AsyncStream<ShellEvent>

    init(_ shell: Shell) {
        self.shell = shell
        // The Shell's pump already drains the SSH channel; this only adapts the stream type.
        events = AsyncStream { continuation in
            let task = Task {
                for await event in shell.events { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func write(_ data: Data) async throws { try await shell.write(data) }
    func resize(cols: UInt32, rows: UInt32) async throws { try await shell.resize(cols: cols, rows: rows) }
    func close() async { try? await shell.close() }
}
