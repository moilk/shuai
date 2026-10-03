import Foundation
import ShuaiCore
import ShuaiPlatform

public struct SessionError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case hostKeyRejected, authFailed, network, timeout, keyMissing, other
    }

    public var kind: Kind
    public var message: String

    public static let hostKeyRejectedMessage = "The host key was not trusted."

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public init(_ error: Error) {
        if let e = error as? SessionError { self = e; return }
        guard let e = error as? FfiSshError else {
            self.init(kind: .other, message: String(describing: error))
            return
        }
        switch e {
        case .Connect(let m): self.init(kind: .network, message: "Could not connect: \(m)")
        case .Timeout: self.init(kind: .timeout, message: "The connection timed out.")
        case .AuthFailed(let tried):
            self.init(kind: .authFailed, message: "Authentication failed (tried: \(tried.joined(separator: ", "))).")
        case .HostKeyRejected: self.init(kind: .hostKeyRejected, message: Self.hostKeyRejectedMessage)
        case .ChannelClosed: self.init(kind: .network, message: "The channel was closed.")
        case .Disconnected: self.init(kind: .network, message: "The connection was lost.")
        case .Protocol(let m): self.init(kind: .other, message: "SSH protocol error: \(m)")
        case .Unsupported(let m): self.init(kind: .other, message: "Unsupported: \(m)")
        case .InvalidKey(let m): self.init(kind: .keyMissing, message: "Invalid key: \(m)")
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    /// TCP + host key accepted; credentials (or a password prompt) are in play.
    case authenticating
    case hostKeyPrompt(HostKeyChallenge)
    case connected
    /// Connection lost; `nextRetryAt` is set while waiting for the next attempt.
    case reconnecting(attempt: Int, nextRetryAt: Date?)
    case failed(SessionError)
    /// Ended on purpose or by the remote exiting (`exitStatus`).
    case disconnected(exitStatus: Int?)

    public enum Status: Equatable, Sendable { case off, busy, connected, warning, error }

    /// Sidebar status dot.
    public var status: Status {
        switch self {
        case .idle, .disconnected: .off
        case .connecting, .authenticating, .hostKeyPrompt: .busy
        case .connected: .connected
        case .reconnecting: .warning
        case .failed: .error
        }
    }
}

/// Something the user must answer before the session can proceed.
public enum SessionPrompt: Equatable, Sendable {
    case hostKey(HostKeyChallenge)
    case password(host: String, username: String)
    case keyboardInteractive(name: String, instructions: String, prompts: [FfiKbdPrompt])
}
