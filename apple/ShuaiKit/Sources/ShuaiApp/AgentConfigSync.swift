import CryptoKit
import Foundation

/// Atomic, private write of `~/.shuai/config.toml` over SSH (tmp file + `mv`, mode 0600).
public enum AgentConfigWriter {
    public static func paths(home: String) -> (dir: String, tmp: String, final: String) {
        let base = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        let dir = base + "/.shuai"
        return (dir, dir + "/config.toml.tmp", dir + "/config.toml")
    }

    public static func write(_ toml: String, remote: AgentRemote, home: String) async throws {
        let p = paths(home: home)
        func run(_ command: String, _ what: String) async throws {
            let out = try await remote.exec(command)
            guard out.ok else {
                let e = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AgentInstallError.commandFailed("\(what) failed" + (e.isEmpty ? "" : ": \(e)"))
            }
        }
        let dir = ShellQuote.quote(p.dir)
        let tmp = ShellQuote.quote(p.tmp)
        let final = ShellQuote.quote(p.final)
        try await run("mkdir -p \(dir) && chmod 700 \(dir)", "mkdir")
        // The file holds the ntfy topic/token: create it 0600 (and drop any old file or symlink)
        // *before* any content is written, so it is never readable by others, even briefly.
        try await run("rm -f \(tmp) && (umask 077 && : > \(tmp))", "prepare config.toml")
        try await remote.upload(Data(toml.utf8), to: p.tmp, mode: 0o600)
        try await run("mv -f \(tmp) \(final) && chmod 600 \(final)", "replace config.toml")
    }

    /// The remote `$HOME` (absolute), for hosts the installer's probe did not run on.
    public static func discoverHome(remote: AgentRemote) async throws -> String {
        let out = try await remote.exec("sh -c " + ShellQuote.quote("printf %s \"${HOME:-$(cd ~ 2>/dev/null && pwd)}\""))
        let home = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.ok, home.hasPrefix("/") else { throw AgentInstallError.commandFailed("Could not find the home directory") }
        return home
    }
}

public enum PushSyncOutcome: Equatable, Sendable {
    case synced
    case upToDate
    case failed(String)
}

/// Keeps every host's `config.toml` in step with the notification settings: written on install,
/// on "Sync to host", and on the next connect when what would be written changed.
@MainActor
public final class PushSyncCoordinator {
    private let settings: PushSettings
    private let defaults: UserDefaults
    private static let ledgerKey = "pushSyncedFingerprints"

    public init(settings: PushSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
    }

    /// The config this host should have right now.
    public func toml(for host: HostProfile) -> String {
        AgentConfigToml.render(hostID: host.id, hostName: host.name, ntfy: settings.config)
    }

    private func fingerprint(_ toml: String) -> String {
        SHA256.hash(data: Data(toml.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func ledger() -> [String: String] { defaults.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:] }

    public func recordSynced(host: HostProfile, toml: String) {
        var l = ledger()
        l[host.id.uuidString] = fingerprint(toml)
        defaults.set(l, forKey: Self.ledgerKey)
    }

    public func forget(host id: UUID) {
        var l = ledger()
        l[id.uuidString] = nil
        defaults.set(l, forKey: Self.ledgerKey)
    }

    /// Automatic path (after connect, agent installed): writes only when the config changed.
    public func syncIfNeeded(host: HostProfile, remote: AgentRemote) async -> PushSyncOutcome {
        let text = toml(for: host)
        if ledger()[host.id.uuidString] == fingerprint(text) { return .upToDate }
        return await write(text, host: host, remote: remote)
    }

    /// Manual "Sync to host".
    public func syncNow(host: HostProfile, remote: AgentRemote) async -> PushSyncOutcome {
        await write(toml(for: host), host: host, remote: remote)
    }

    private func write(_ text: String, host: HostProfile, remote: AgentRemote) async -> PushSyncOutcome {
        do {
            let home = try await AgentConfigWriter.discoverHome(remote: remote)
            try await AgentConfigWriter.write(text, remote: remote, home: home)
            recordSynced(host: host, toml: text)
            return .synced
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
