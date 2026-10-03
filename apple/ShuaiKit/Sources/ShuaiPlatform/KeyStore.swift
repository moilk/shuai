import Foundation
import ShuaiCore

/// Non-secret metadata of a stored private key.
public struct KeyRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var algorithm: String
    public var fingerprint: String
    public var publicLine: String
    public var createdAt: Date

    public init(id: String, name: String, algorithm: String, fingerprint: String, publicLine: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.publicLine = publicLine
        self.createdAt = createdAt
    }

    public init(id: String, name: String, material: KeyMaterial, createdAt: Date = Date()) {
        self.init(
            id: id, name: name, algorithm: material.algorithm, fingerprint: material.fingerprint,
            publicLine: material.publicLine, createdAt: createdAt)
    }
}

public enum KeyStoreError: Error, Equatable, Sendable {
    /// A Security framework call failed with this `OSStatus`.
    case keychain(Int32)
    /// Stored data could not be decoded.
    case corrupt
}

/// Storage for private-key PEMs (secret) plus their metadata (not secret).
///
/// `KeychainKeyStore` is the production implementation; `InMemoryKeyStore` is for tests and
/// environments without a usable keychain.
public protocol KeyStore: Sendable {
    /// Inserts or replaces the key with `record.id`.
    func save(privatePem: String, record: KeyRecord) throws
    func loadPrivatePem(id: String) throws -> String?
    /// Deleting a missing key is not an error.
    func delete(id: String) throws
    /// Oldest first.
    func list() throws -> [KeyRecord]
}

/// JSON-file (or purely in-memory) metadata list shared by the store implementations.
final class KeyMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL?
    private var records: [String: KeyRecord] = [:]

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            if let list = try? dec.decode([KeyRecord].self, from: data) {
                records = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            }
        }
    }

    func upsert(_ r: KeyRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[r.id] = r
        try persist()
    }

    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        records[id] = nil
        try persist()
    }

    func all() -> [KeyRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let sorted = records.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        try enc.encode(sorted).write(to: url, options: .atomic)
    }

    static func defaultURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("keys.json")
    }
}

func applicationSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("shuai", isDirectory: true)
}

public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pems: [String: String] = [:]
    private let metadata: KeyMetadata

    /// `metadataURL` optionally persists the (non-secret) metadata, to test reopen behaviour.
    public init(metadataURL: URL? = nil) {
        metadata = KeyMetadata(url: metadataURL)
    }

    public func save(privatePem: String, record: KeyRecord) throws {
        lock.lock(); pems[record.id] = privatePem; lock.unlock()
        try metadata.upsert(record)
    }

    public func loadPrivatePem(id: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return pems[id]
    }

    public func delete(id: String) throws {
        lock.lock(); pems[id] = nil; lock.unlock()
        try metadata.remove(id: id)
    }

    public func list() throws -> [KeyRecord] { metadata.all() }
}
