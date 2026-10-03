import Foundation
import ShuaiCore
import ShuaiPlatform

/// Result of a one-shot remote command.
public struct RemoteExecOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    /// `nil` when the command died from a signal.
    public var exitStatus: Int?

    public init(stdout: String = "", stderr: String = "", exitStatus: Int? = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var ok: Bool { exitStatus == 0 }
    public static func ok(_ stdout: String = "") -> RemoteExecOutput { .init(stdout: stdout) }
    public static func fail(_ status: Int, _ stderr: String = "") -> RemoteExecOutput {
        .init(stderr: stderr, exitStatus: status)
    }
}

public enum AgentStreamEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    /// Exit status (`nil` for a signal). Followed by `.closed`.
    case exited(Int?)
    case closed
}

/// A running remote command whose output must be drained continuously.
public protocol AgentStream: Sendable {
    var events: AsyncStream<AgentStreamEvent> { get }
    func close() async
}

/// What the agent monitor and installer need from an authenticated SSH connection
/// (real: `LiveAgentRemote`; tests: a fake).
public protocol AgentRemote: Sendable {
    func exec(_ command: String) async throws -> RemoteExecOutput
    func execStream(_ command: String) async throws -> AgentStream
    func upload(_ data: Data, to path: String, mode: UInt32) async throws
}

// MARK: - Live implementation over ShuaiPlatform.Connection

public struct LiveAgentRemote: AgentRemote {
    private let connection: Connection
    public init(connection: Connection) { self.connection = connection }

    public func exec(_ command: String) async throws -> RemoteExecOutput {
        let r = try await connection.exec(command)
        return RemoteExecOutput(
            stdout: String(decoding: r.stdout, as: UTF8.self),
            stderr: String(decoding: r.stderr, as: UTF8.self),
            exitStatus: r.exitStatus.map(Int.init))
    }

    public func execStream(_ command: String) async throws -> AgentStream {
        LiveAgentStream(try await connection.execStream(command))
    }

    public func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        try await connection.upload(data, to: path, mode: mode)
    }
}

final class LiveAgentStream: AgentStream {
    private let session: ExecSession
    let events: AsyncStream<AgentStreamEvent>

    init(_ session: ExecSession) {
        self.session = session
        // The ExecSession pump already drains the SSH channel; this adapts the event type.
        events = AsyncStream { continuation in
            let task = Task {
                for await e in session.events {
                    switch e {
                    case .stdout(let b): continuation.yield(.stdout(b))
                    case .stderr(let b): continuation.yield(.stderr(b))
                    case .exitStatus(let s): continuation.yield(.exited(Int(s)))
                    case .exitSignal: continuation.yield(.exited(nil))
                    case .closed: continuation.yield(.closed)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() async { try? await session.close() }
}

// MARK: - Shell quoting

public enum ShellQuote {
    /// POSIX single-quote quoting; plain safe strings stay unquoted.
    public static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-:@%+=,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
