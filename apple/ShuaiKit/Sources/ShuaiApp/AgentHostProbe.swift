import Foundation

/// What the cheap per-connection probe learned about a host.
public struct AgentHostInfo: Equatable, Sendable {
    /// The name the agent stamps on its events (`SHUAI_HOSTNAME` or `uname -n`): the key of the
    /// agent tracker, NOT the app's host profile id (see `AgentHub`).
    public var hostname: String
    /// Version of `~/.shuai/bin/shuai-agent`, nil when it is not installed.
    public var agentVersion: String?
    public var claudePath: String?

    public init(hostname: String, agentVersion: String?, claudePath: String?) {
        self.hostname = hostname
        self.agentVersion = agentVersion
        self.claudePath = claudePath
    }
}

/// One `sh -c` exec per connection: the remote hostname exactly as `shuai-agent` computes it,
/// the installed agent's version and the `claude` binary (for the periodic reconcile).
public enum AgentHostProbe {
    static let script = """
        echo "host=${SHUAI_HOSTNAME:-$(uname -n)}"; \
        v=$("$HOME/.shuai/bin/shuai-agent" --version 2>/dev/null) && echo "agent=$v"; \
        c=$(command -v claude 2>/dev/null) && echo "claude=$c"; \
        true
        """

    public static var command: String { "sh -c " + ShellQuote.quote(script) }

    public static func parse(_ out: RemoteExecOutput) -> AgentHostInfo? {
        guard out.ok else { return nil }
        var host: String?
        var agent: String?
        var claude: String?
        for raw in out.stdout.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = line.value(after: "host=") { host = v }
            else if let v = line.value(after: "agent=") { agent = v.split(separator: " ").last.map(String.init) }
            else if let v = line.value(after: "claude=") { claude = v }
        }
        guard let host, !host.isEmpty else { return nil }
        return AgentHostInfo(hostname: host, agentVersion: agent, claudePath: claude)
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let v = String(dropFirst(prefix.count))
        return v.isEmpty ? nil : v
    }
}

/// Is the AI integration set up on this host?
public enum AgentHostStatus: Equatable, Sendable {
    /// Not connected yet, or the probe failed.
    case unknown
    case notInstalled
    case installed(version: String)
    /// Installed but older than the agent bundled with this app.
    case outdated(installed: String, bundled: String)

    public static func make(installed: String?, bundled: String) -> AgentHostStatus {
        guard let installed else { return .notInstalled }
        if let a = components(installed), let b = components(bundled), compare(a, b) < 0 {
            return .outdated(installed: installed, bundled: bundled)
        }
        return .installed(version: installed)
    }

    private static func components(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }

    private static func padded(_ a: [Int], to n: Int) -> [Int] { a + Array(repeating: 0, count: max(0, n - a.count)) }

    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        let n = max(a.count, b.count)
        let x = padded(a, to: n), y = padded(b, to: n)
        for i in 0 ..< n where x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
        return 0
    }

    /// Short text for the host row.
    public var label: String {
        switch self {
        case .unknown: ""
        case .notInstalled: "AI integration off"
        case .installed(let v): "AI integration \(v)"
        case .outdated(let v, let b): "AI integration \(v) (update to \(b))"
        }
    }

    public var isInstalled: Bool {
        switch self {
        case .installed, .outdated: true
        default: false
        }
    }
}
