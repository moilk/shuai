import Foundation
import Observation

public enum HostStoreError: Error, Equatable, Sendable {
    /// The file on disk was written by a newer app version; we refuse to overwrite it.
    case newerSchema(Int)
    case corrupt
    case notFound
    case io(String)
}

/// Host profiles persisted as JSON (`{"version":1,"hosts":[...]}`) in Application Support.
/// Writes are atomic. A legacy bare array (v0) is migrated on load; a newer schema is left
/// untouched and the store becomes read-only (`add`/`update`/`delete` throw).
@MainActor @Observable
public final class HostStore {
    public static let currentVersion = 1

    public private(set) var hosts: [HostProfile] = []
    public private(set) var loadError: HostStoreError?
    @ObservationIgnored public let fileURL: URL

    public init(fileURL: URL = HostStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    public nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("shuai", isDirectory: true).appendingPathComponent("hosts.json")
    }

    public func host(id: UUID) -> HostProfile? { hosts.first { $0.id == id } }

    public func add(_ host: HostProfile) throws {
        try guardWritable()
        hosts.append(host)
        try persist()
    }

    public func update(_ host: HostProfile) throws {
        try guardWritable()
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { throw HostStoreError.notFound }
        hosts[i] = host
        try persist()
    }

    public func delete(id: UUID) throws {
        try guardWritable()
        hosts.removeAll { $0.id == id }
        try persist()
    }

    public func markConnected(id: UUID, at date: Date = Date()) throws {
        try guardWritable()
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { throw HostStoreError.notFound }
        hosts[i].lastConnectedAt = date
        try persist()
    }

    // MARK: - persistence

    private struct File: Codable {
        var version: Int
        var hosts: [HostProfile]
    }

    private struct VersionProbe: Decodable { var version: Int }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func guardWritable() throws {
        if case .newerSchema = loadError { throw loadError! }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = Self.decoder()
        if let probe = try? dec.decode(VersionProbe.self, from: data) {
            if probe.version > Self.currentVersion {
                loadError = .newerSchema(probe.version)
                return
            }
            if let file = try? dec.decode(File.self, from: data) {
                hosts = file.hosts
                return
            }
        } else if let legacy = try? dec.decode([HostProfile].self, from: data) {
            hosts = legacy
            try? persist() // rewrite in the current schema
            return
        }
        // Unreadable: keep a copy for recovery and start fresh.
        loadError = .corrupt
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("hosts.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(File(version: Self.currentVersion, hosts: hosts)).write(to: fileURL, options: .atomic)
            if loadError == .corrupt { loadError = nil }
        } catch {
            throw HostStoreError.io(String(describing: error))
        }
    }
}
