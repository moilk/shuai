import Foundation
import ShuaiCore

// IMPORTANT (shuai-ssh): every open channel must be drained continuously, otherwise the whole
// session stalls (including keepalives). `Shell` and `ExecSession` start a pump task at
// creation that reads events from Rust as fast as they arrive into a byte-bounded, coalescing
// queue (see EventPump.swift for the back-pressure trade-off). Terminal bytes are never dropped.
//
// Lifetimes: a `Shell`/`ExecSession` (or its `events` stream) keeps its `Connection` alive;
// the `Connection` disconnects when the last reference to it goes away. Cancelling the
// consumer of `events`, calling `close()`, or dropping every reference stops the pump task and
// closes the Rust stream.
//
// Callbacks: Rust invokes `HostKeyVerifierCallback`/`KbdPrompterCallback` (async) and
// `SignerCallback` (sync, on a blocking-capable thread) from tokio threads. Implementations
// must not block on work that itself waits for the Rust runtime (e.g. do not call a blocking
// wrapper around `Connection` APIs from `SignerCallback.sign`). Blocking on a biometric prompt
// is fine because shuai-ssh runs the signer via `spawn_blocking`.

/// An interactive PTY shell. Consume `events`; the stream finishes after `.closed`.
public final class Shell: Sendable {
    private let stream: ShellStream
    private let core: PumpCore<ShellEvent>
    public let events: EventStream<ShellEvent>

    init(stream: ShellStream, owner: Connection, bufferBytes: Int) {
        self.stream = stream
        let core = PumpCore<ShellEvent>(
            capacityBytes: bufferBytes, owner: owner,
            next: { await stream.nextEvent() },
            close: { try? await stream.close() })
        self.core = core
        self.events = core.events
    }

    public func write(_ data: Data) async throws { try await stream.write(data: data) }
    public func resize(cols: UInt32, rows: UInt32) async throws { try await stream.resize(cols: cols, rows: rows) }
    public func close() async throws { try await stream.close() }
}

/// A running remote command with streamed output.
public final class ExecSession: Sendable {
    private let stream: ExecStream
    private let core: PumpCore<ExecEvent>
    public let events: EventStream<ExecEvent>

    init(stream: ExecStream, owner: Connection, bufferBytes: Int) {
        self.stream = stream
        let core = PumpCore<ExecEvent>(
            capacityBytes: bufferBytes, owner: owner,
            next: { await stream.nextEvent() },
            close: { try? await stream.close() })
        self.core = core
        self.events = core.events
    }

    public func writeStdin(_ data: Data) async throws { try await stream.writeStdin(data: data) }
    public func eof() async throws { try await stream.eof() }
    public func close() async throws { try await stream.close() }
}

/// One authenticated SSH session.
public actor Connection {
    private let inner: SshConnection

    private init(inner: SshConnection) { self.inner = inner }

    deinit {
        // Last reference gone (no Shell/ExecSession/stream keeps us alive any more).
        let inner = inner
        Task.detached { try? await inner.disconnect() }
    }

    public static let defaultEnv = [FfiEnvVar(name: "COLORTERM", value: "truecolor")]

    /// Per-stream cap on buffered, not yet consumed output. When reached the pump waits for
    /// the consumer, which (by SSH flow control) stalls the whole session. See EventPump.swift.
    public static let defaultStreamBufferBytes = 64 * 1024 * 1024

    public static func connect(config: FfiConnectConfig, verifier: HostKeyVerifierCallback) async throws -> Connection {
        Connection(inner: try await SshConnection.connect(config: config, hostKeyVerifier: verifier))
    }

    public func openShell(
        cols: UInt32, rows: UInt32, term: String = "xterm-256color", env: [FfiEnvVar] = Connection.defaultEnv,
        bufferBytes: Int = Connection.defaultStreamBufferBytes
    ) async throws -> Shell {
        Shell(
            stream: try await inner.openShell(cols: cols, rows: rows, term: term, env: env),
            owner: self, bufferBytes: bufferBytes)
    }

    /// Runs `command` directly on a PTY (no login shell, nothing typed or echoed), e.g.
    /// `tmux new -A -s NAME`. Behaves like a shell: write/resize/events.
    public func openPtyExec(
        command: String, cols: UInt32, rows: UInt32, term: String = "xterm-256color",
        env: [FfiEnvVar] = Connection.defaultEnv, bufferBytes: Int = Connection.defaultStreamBufferBytes
    ) async throws -> Shell {
        Shell(
            stream: try await inner.openPtyExec(command: command, cols: cols, rows: rows, term: term, env: env),
            owner: self, bufferBytes: bufferBytes)
    }

    public func exec(_ command: String) async throws -> ExecResult {
        try await inner.exec(cmd: command)
    }

    public func execStream(
        _ command: String, bufferBytes: Int = Connection.defaultStreamBufferBytes
    ) async throws -> ExecSession {
        ExecSession(stream: try await inner.execStream(cmd: command), owner: self, bufferBytes: bufferBytes)
    }

    /// Uploads `data` to `path` with permissions `mode` (streamed through `cat > path`).
    public func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        try await inner.upload(data: data, remotePath: path, mode: mode)
    }

    /// Resolves when the session ends.
    public nonisolated func closed() async -> CloseReason { await inner.closed() }

    public func disconnect() async { try? await inner.disconnect() }
}
