import Foundation
import ShuaiCore

// IMPORTANT (shuai-ssh): every open channel must be drained continuously, otherwise the whole
// session stalls (including keepalives). `Shell` and `ExecSession` start a pump task at
// creation that reads events from Rust as fast as they arrive and yields them to an
// *unbounded* AsyncThrowingStream, so a slow consumer never back-pressures the SSH session.

/// An interactive PTY shell. Consume `events`; the stream finishes after `.closed`.
public final class Shell: Sendable {
    private let stream: ShellStream
    public let events: AsyncThrowingStream<ShellEvent, Error>

    init(stream: ShellStream) {
        self.stream = stream
        let (events, continuation) = AsyncThrowingStream<ShellEvent, Error>.makeStream()
        self.events = events
        let pump = Task.detached {
            while !Task.isCancelled {
                let ev = await stream.nextEvent()
                continuation.yield(ev)
                if case .closed = ev { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            pump.cancel()
            Task { try? await stream.close() }
        }
    }

    public func write(_ data: Data) async throws { try await stream.write(data: data) }
    public func resize(cols: UInt32, rows: UInt32) async throws { try await stream.resize(cols: cols, rows: rows) }
    public func close() async throws { try await stream.close() }
}

/// A running remote command with streamed output.
public final class ExecSession: Sendable {
    private let stream: ExecStream
    public let events: AsyncThrowingStream<ExecEvent, Error>

    init(stream: ExecStream) {
        self.stream = stream
        let (events, continuation) = AsyncThrowingStream<ExecEvent, Error>.makeStream()
        self.events = events
        let pump = Task.detached {
            while !Task.isCancelled {
                let ev = await stream.nextEvent()
                continuation.yield(ev)
                if case .closed = ev { break }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            pump.cancel()
            Task { try? await stream.close() }
        }
    }

    public func writeStdin(_ data: Data) async throws { try await stream.writeStdin(data: data) }
    public func eof() async throws { try await stream.eof() }
    public func close() async throws { try await stream.close() }
}

/// One authenticated SSH session.
public actor Connection {
    private let inner: SshConnection

    private init(inner: SshConnection) { self.inner = inner }

    public static let defaultEnv = [FfiEnvVar(name: "COLORTERM", value: "truecolor")]

    public static func connect(config: FfiConnectConfig, verifier: HostKeyVerifierCallback) async throws -> Connection {
        Connection(inner: try await SshConnection.connect(config: config, hostKeyVerifier: verifier))
    }

    public func openShell(
        cols: UInt32, rows: UInt32, term: String = "xterm-256color", env: [FfiEnvVar] = Connection.defaultEnv
    ) async throws -> Shell {
        Shell(stream: try await inner.openShell(cols: cols, rows: rows, term: term, env: env))
    }

    public func exec(_ command: String) async throws -> ExecResult {
        try await inner.exec(cmd: command)
    }

    public func execStream(_ command: String) async throws -> ExecSession {
        ExecSession(stream: try await inner.execStream(cmd: command))
    }

    /// Uploads `data` to `path` with permissions `mode` (streamed through `cat > path`).
    public func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        try await inner.upload(data: data, remotePath: path, mode: mode)
    }

    /// Resolves when the session ends.
    public nonisolated func closed() async -> CloseReason { await inner.closed() }

    public func disconnect() async { try? await inner.disconnect() }
}
