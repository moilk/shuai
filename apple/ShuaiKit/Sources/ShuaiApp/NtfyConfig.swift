import Foundation
import Security

// Pure helpers for the ntfy push setup: the private topic, the server URL, the config the agent
// reads, and the status-only test request. Nothing here ever sees agent event content.

/// A random private topic. On the public server the topic IS the secret, so it carries 128 bits.
public enum NtfyTopic {
    public static let prefix = "shuai-"
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// `shuai-` + 26 lowercase base32 characters (16 random bytes, RFC 4648 without padding).
    public static func generate(randomBytes: (Int) -> [UInt8] = NtfyTopic.secureRandom) -> String {
        prefix + base32(randomBytes(16))
    }

    public static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Also a CSPRNG (getentropy-backed); never a weak fallback.
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        return bytes
    }

    static func base32(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// ntfy accepts `[A-Za-z0-9_-]{1,64}`.
    public static func isValid(_ topic: String) -> Bool {
        (1 ... 64).contains(topic.utf8.count) && topic.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }
}

public enum NtfyServer {
    public enum Reason: Equatable, Sendable {
        case empty, notAURL, unsupportedScheme, missingHost, hasCredentials, hasQueryOrFragment

        public var message: String {
            switch self {
            case .empty: "Enter a server URL."
            case .notAURL: "That is not a valid URL."
            case .unsupportedScheme: "Use an https:// (or http://) URL."
            case .missingHost: "The URL has no host name."
            case .hasCredentials: "Put the access token in the token field, not in the URL."
            case .hasQueryOrFragment: "Remove the query or fragment from the URL."
            }
        }
    }

    public enum Validation: Equatable, Sendable {
        case valid(URL)
        /// Plain http: works, but the topic and token travel unencrypted.
        case insecure(URL)
        case invalid(Reason)

        public var url: URL? {
            switch self {
            case .valid(let u), .insecure(let u): u
            case .invalid: nil
            }
        }
    }

    public static let insecureWarning = "http:// sends the topic and token unencrypted. Use it only on a trusted network."

    /// Normalises (trims, drops a trailing slash) and classifies a user-entered server URL.
    public static func validate(_ text: String) -> Validation {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .invalid(.empty) }
        guard let c = URLComponents(string: t), t.allSatisfy({ !$0.isWhitespace }) else { return .invalid(.notAURL) }
        guard let scheme = c.scheme?.lowercased() else { return .invalid(.notAURL) }
        guard scheme == "https" || scheme == "http" else { return .invalid(.unsupportedScheme) }
        guard let host = c.host, !host.isEmpty else { return .invalid(.missingHost) }
        if c.user != nil || c.password != nil { return .invalid(.hasCredentials) }
        if c.query != nil || c.fragment != nil { return .invalid(.hasQueryOrFragment) }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        var s = "\(scheme)://"
        s += host.contains(":") ? "[\(host)]" : host
        if let p = c.port { s += ":\(p)" }
        s += path
        guard let url = URL(string: s) else { return .invalid(.notAURL) }
        return scheme == "https" ? .valid(url) : .insecure(url)
    }

    /// `ntfy://<host>/<topic>`: opens (and subscribes in) the official ntfy app. Not possible
    /// for a server under a sub-path.
    public static func appLink(server: URL, topic: String) -> URL? {
        guard NtfyTopic.isValid(topic), let host = server.host, server.path.isEmpty || server.path == "/" else { return nil }
        var s = "ntfy://" + (host.contains(":") ? "[\(host)]" : host)
        if let p = server.port { s += ":\(p)" }
        s += "/\(topic)"
        if server.scheme == "http" { s += "?secure=false" }
        return URL(string: s)
    }
}

/// What the agent needs to push: written to `[ntfy]` in the host's `config.toml`.
public struct NtfyConfig: Equatable, Sendable {
    public var server: String
    public var topic: String
    public var token: String?
    /// Send tmux window names in pushes. Off: automatic-rename makes them the running command line.
    public var includeWindowNames: Bool

    public init(server: String, topic: String, token: String? = nil, includeWindowNames: Bool = false) {
        self.server = server
        self.topic = topic
        self.token = token
        self.includeWindowNames = includeWindowNames
    }
}

/// Renders `~/.shuai/config.toml`. Every string is escaped as a TOML basic string, so no value
/// (host name, token, ...) can break out of its quotes or inject keys.
public enum AgentConfigToml {
    public static func render(hostID: UUID, hostName: String, ntfy: NtfyConfig?) -> String {
        var out = "# Written by the Shuai app. Changes are overwritten.\n"
        out += "host_id = \(quote(hostID.uuidString))\n"
        out += "host_name = \(quote(hostName))\n"
        if let n = ntfy {
            out += "\n[ntfy]\n"
            out += "server = \(quote(n.server))\n"
            out += "topic = \(quote(n.topic))\n"
            if let t = n.token, !t.isEmpty { out += "token = \(quote(t))\n" }
            if n.includeWindowNames { out += "window_names = true\n" }
        }
        return out
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += "\\u" + String(format: "%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

/// The "send test notification" request: status-only text, posted by the app itself.
public enum NtfyTestRequest {
    public static func build(config: NtfyConfig) -> URLRequest? {
        guard let base = URL(string: config.server), NtfyTopic.isValid(config.topic) else { return nil }
        var r = URLRequest(url: base.appendingPathComponent(config.topic), timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("Shuai test notification", forHTTPHeaderField: "Title")
        r.setValue("white_check_mark", forHTTPHeaderField: "Tags")
        if let t = config.token, !t.isEmpty { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        r.httpBody = Data("Push notifications are working.".utf8)
        return r
    }
}

public protocol NtfyTransport: Sendable {
    /// Sends the request, returns the HTTP status.
    func send(_ request: URLRequest) async throws -> Int
}

public struct URLSessionNtfyTransport: NtfyTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
