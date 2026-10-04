import Foundation

public enum DeepLinkError: Error, Equatable, Sendable {
    /// Not a `shuai://open` link at all.
    case notOurs
    case malformed
}

/// `shuai://open?host=<HostProfile UUID>&pane=<%N>` (the agent's push click URL). `pane` is
/// optional; anything that does not parse strictly is rejected, never guessed.
public struct DeepLink: Equatable, Sendable {
    public var hostID: UUID
    public var pane: String?

    public init(hostID: UUID, pane: String?) {
        self.hostID = hostID
        self.pane = pane
    }

    /// tmux pane ids: `%` and decimal digits (bounded, so a hostile link cannot smuggle commands).
    public static func isValidPane(_ s: String) -> Bool {
        guard s.hasPrefix("%") else { return false }
        let digits = s.dropFirst()
        // ASCII bytes only: Character comparison would accept "5" + a combining accent.
        return (1 ... 9).contains(digits.utf8.count) && digits.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    public static func parse(_ url: URL) -> Result<DeepLink, DeepLinkError> {
        guard url.scheme?.lowercased() == "shuai" else { return .failure(.notOurs) }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host?.lowercased() == "open",
            c.path.isEmpty || c.path == "/", c.user == nil, c.password == nil, c.port == nil
        else { return .failure(.malformed) }
        let items = c.queryItems ?? []
        func values(_ name: String) -> [String?] { items.filter { $0.name == name }.map(\.value) }
        let hosts = values("host")
        guard hosts.count == 1, let hostText = hosts[0], let hostID = UUID(uuidString: hostText) else { return .failure(.malformed) }
        let panes = values("pane")
        guard panes.count <= 1 else { return .failure(.malformed) }
        guard let pane = panes.first else { return .success(DeepLink(hostID: hostID, pane: nil)) }
        guard let pane, isValidPane(pane) else { return .failure(.malformed) }
        return .success(DeepLink(hostID: hostID, pane: pane))
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "shuai"
        c.host = "open"
        // `%` in the pane id must itself be percent-encoded.
        var q = "host=\(hostID.uuidString)"
        if let pane { q += "&pane=" + (pane.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
        c.percentEncodedQuery = q
        return c.url!
    }
}

public enum PaneNavigationResult: Equatable, Sendable {
    case opened
    case paneNotFound
    case connectionFailed
}

/// What the app does for a link: select the host (connecting if needed) and show the pane.
@MainActor
public protocol PaneNavigating: AnyObject {
    func hostExists(_ id: UUID) -> Bool
    func navigate(hostID: UUID, pane: String?) async -> PaneNavigationResult
}

public enum DeepLinkOutcome: Equatable, Sendable {
    case opened
    /// Not for us (another URL scheme).
    case ignored
    /// Show this to the user.
    case notice(String)
}

/// Shared by URL opens (`onOpenURL`) and local-notification taps.
@MainActor
public struct DeepLinkRouter {
    private let navigator: PaneNavigating

    public init(navigator: PaneNavigating) { self.navigator = navigator }

    public func handle(_ url: URL) async -> DeepLinkOutcome {
        switch DeepLink.parse(url) {
        case .success(let link): return await handle(link)
        case .failure(.notOurs): return .ignored
        case .failure(.malformed): return .notice("That link is not a valid Shuai link.")
        }
    }

    public func handle(_ link: DeepLink) async -> DeepLinkOutcome {
        guard navigator.hostExists(link.hostID) else {
            return .notice("This link is for a host that is not in Shuai on this iPad.")
        }
        switch await navigator.navigate(hostID: link.hostID, pane: link.pane) {
        case .opened: return .opened
        case .paneNotFound: return .notice("That pane no longer exists. Showing the host instead.")
        case .connectionFailed: return .notice("Could not connect to the host to open that pane.")
        }
    }
}
