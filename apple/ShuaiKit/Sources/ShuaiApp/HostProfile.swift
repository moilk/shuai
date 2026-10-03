import Foundation

public struct TmuxPrefs: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sessionName: String

    public init(enabled: Bool = true, sessionName: String = "shuai") {
        self.enabled = enabled
        self.sessionName = sessionName
    }

    // Tolerant decoding: missing fields fall back to defaults (older/hand-edited files).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? "shuai"
    }
}

/// How a host authenticates. Secrets are never stored in the profile: keys live in the key
/// store (referenced by id), passwords in the Keychain (`PasswordStore`, keyed by host id).
public enum HostAuth: Codable, Equatable, Sendable {
    case key(keyID: String)
    case password
    /// Ask for a password on every connect.
    case ask

    private enum CodingKeys: String, CodingKey { case type, keyID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "key": self = .key(keyID: try c.decode(String.self, forKey: .keyID))
        case "password": self = .password
        default: self = .ask
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let id):
            try c.encode("key", forKey: .type)
            try c.encode(id, forKey: .keyID)
        case .password: try c.encode("password", forKey: .type)
        case .ask: try c.encode("ask", forKey: .type)
        }
    }
}

public enum HostValidationError: Hashable, Sendable {
    case name, host, port, username, key, tmuxSessionName
}

public struct HostProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: HostAuth
    public var tmux: TmuxPrefs
    public var startupCommand: String?
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
        auth: HostAuth = .ask, tmux: TmuxPrefs = TmuxPrefs(), startupCommand: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.tmux = tmux
        self.startupCommand = startupCommand
        self.lastConnectedAt = lastConnectedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decodeIfPresent(HostAuth.self, forKey: .auth) ?? .ask
        tmux = try c.decodeIfPresent(TmuxPrefs.self, forKey: .tmux) ?? TmuxPrefs()
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public var validationErrors: [HostValidationError] {
        var out: [HostValidationError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.name) }
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty || h.contains(where: \.isWhitespace) { out.append(.host) }
        if !(1 ... 65535).contains(port) { out.append(.port) }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.username) }
        if case .key(let id) = auth, id.isEmpty { out.append(.key) }
        if tmux.enabled, !TmuxLaunch.isValidSessionName(tmux.sessionName) { out.append(.tmuxSessionName) }
        return out
    }

    /// `user@host` (with `:port` unless it is 22).
    public var displayTarget: String {
        port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
    }
}
