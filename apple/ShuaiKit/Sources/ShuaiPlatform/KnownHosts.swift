import Foundation
import ShuaiCore

/// File-backed OpenSSH `known_hosts` text; all parsing and matching happens in Rust.
public final class KnownHostsStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL

    public init(fileURL: URL = KnownHostsStore.defaultFileURL()) {
        url = fileURL
    }

    public static func defaultFileURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("known_hosts")
    }

    /// Current file contents (empty if the file does not exist yet).
    public func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return readText()
    }

    public func check(host: String, port: UInt16, publicKeyLine: String) throws -> FfiHostKeyStatus {
        try knownHostsCheck(text: text(), host: host, port: port, publicKeyLine: publicKeyLine)
    }

    /// Appends an entry for `host:port`.
    public func add(host: String, port: UInt16, publicKeyLine: String, hashed: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        let new = try knownHostsAdd(
            text: readText(), host: host, port: port, publicKeyLine: publicKeyLine, hashed: hashed)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try new.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readText() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// What the user is asked to decide about.
public struct HostKeyChallenge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// First time this host is seen (trust on first use).
        case unknown
        /// The host presented a key different from the recorded one(s): possible MITM.
        case changed(expectedFingerprints: [String])
    }

    public var host: String
    public var port: UInt16
    public var publicKeyLine: String
    public var fingerprint: String
    public var kind: Kind
}

/// Trust-on-first-use host key verifier. Known keys pass silently, revoked keys fail, and
/// unknown or changed keys are put to `decide` (typically a UI prompt); accepted keys are
/// remembered in the `KnownHostsStore`.
public final class TOFUVerifier: HostKeyVerifierCallback {
    private let store: KnownHostsStore
    private let decide: @Sendable (HostKeyChallenge) async -> Bool

    public init(store: KnownHostsStore, decide: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.store = store
        self.decide = decide
    }

    public func verify(host: String, port: UInt16, publicKeyLine: String) async -> Bool {
        guard let status = try? store.check(host: host, port: port, publicKeyLine: publicKeyLine),
              let fingerprint = try? publicKeyFingerprint(publicKeyLine: publicKeyLine)
        else { return false }
        let kind: HostKeyChallenge.Kind
        switch status {
        case .trusted: return true
        case .revoked: return false
        case .unknown: kind = .unknown
        case .mismatch(let expected): kind = .changed(expectedFingerprints: expected)
        }
        let challenge = HostKeyChallenge(
            host: host, port: port, publicKeyLine: publicKeyLine, fingerprint: fingerprint, kind: kind)
        guard await decide(challenge) else { return false }
        return (try? store.add(host: host, port: port, publicKeyLine: publicKeyLine)) != nil
    }
}
