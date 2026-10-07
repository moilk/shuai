import Foundation

/// The connection item of a host's context menu: a touch path that does not need the terminal's
/// navigation bar. Hosts without a live session offer Connect, everything else Disconnect (which also
/// cancels a connect or a reconnect in progress).
public enum HostConnectionMenu {
    public enum Item: Equatable, Sendable {
        case connect, disconnect

        public var title: String {
            switch self {
            case .connect: "Connect"
            case .disconnect: "Disconnect"
            }
        }

        public var symbol: String {
            switch self {
            case .connect: "bolt"
            case .disconnect: "bolt.slash"
            }
        }
    }

    /// `state` is nil while the host has no session controller yet.
    public static func item(for state: SessionState?) -> Item {
        switch state {
        case nil, .idle?, .failed?, .disconnected?: .connect
        case .connecting?, .authenticating?, .hostKeyPrompt?, .connected?, .reconnecting?: .disconnect
        }
    }
}
