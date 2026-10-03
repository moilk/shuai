import Foundation
import Observation
import ShuaiCore
import ShuaiPlatform

public enum KeyLibraryError: Error, Equatable, Sendable {
    case needsPassphrase
    case wrongPassphrase
    case invalidKey
    case store(String)
}

public enum GeneratedKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519
    case ecdsaP256
    public var id: String { rawValue }
    public var label: String { self == .ed25519 ? "ed25519" : "ecdsa (P-256)" }
    var ffi: KeyAlg { self == .ed25519 ? .ed25519 : .ecdsaP256 }
}

/// User-facing key management over a `KeyStore` (Keychain in production).
@MainActor @Observable
public final class KeyLibrary {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var algorithm: String
        public var fingerprint: String
        public var publicLine: String
        public var randomart: String
        public var createdAt: Date
    }

    public private(set) var items: [Item] = []
    @ObservationIgnored private let store: KeyStore
    @ObservationIgnored private let makeID: () -> String

    public init(store: KeyStore, makeID: @escaping () -> String = { UUID().uuidString }) {
        self.store = store
        self.makeID = makeID
        reload()
    }

    public func reload() {
        let records = (try? store.list()) ?? []
        items = records.map { r in
            let art = (try? store.loadPrivatePem(id: r.id)).flatMap { $0 }.flatMap { try? publicInfo(privatePem: $0).randomart }
            return Item(
                id: r.id, name: r.name, algorithm: r.algorithm, fingerprint: r.fingerprint,
                publicLine: r.publicLine, randomart: art ?? "", createdAt: r.createdAt)
        }
    }

    @discardableResult
    public func generate(name: String, algorithm: GeneratedKeyAlgorithm) throws -> Item {
        do {
            let material = try generateKey(alg: algorithm.ffi, comment: "shuai")
            return try save(material, name: name, fallbackName: "\(algorithm.rawValue) key")
        } catch let e as FfiKeyError { throw Self.map(e) }
    }

    /// Imports OpenSSH/PEM (PKCS#1/#8, SEC1), encrypted or not. The stored PEM is decrypted.
    @discardableResult
    public func importKey(data: Data, name: String, passphrase: String?) throws -> Item {
        do {
            let material = try ffiImportKey(data, passphrase)
            return try save(material, name: name, fallbackName: "imported key")
        } catch let e as FfiKeyError { throw Self.map(e) }
    }

    @discardableResult
    public func importKey(text: String, name: String, passphrase: String?) throws -> Item {
        try importKey(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8), name: name, passphrase: passphrase)
    }

    public func delete(id: String) throws {
        do { try store.delete(id: id) } catch { throw KeyLibraryError.store(String(describing: error)) }
        items.removeAll { $0.id == id }
    }

    public func publicKeyLine(id: String) -> String? { items.first { $0.id == id }?.publicLine }

    public func privatePem(id: String) throws -> String? { try store.loadPrivatePem(id: id) }

    private func save(_ material: KeyMaterial, name: String, fallbackName: String) throws -> Item {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = KeyRecord(id: makeID(), name: trimmed.isEmpty ? fallbackName : trimmed, material: material)
        do { try store.save(privatePem: material.privatePem, record: record) } catch {
            throw KeyLibraryError.store(String(describing: error))
        }
        reload()
        return items.first { $0.id == record.id }!
    }

    private static func map(_ e: FfiKeyError) -> KeyLibraryError {
        switch e {
        case .NeedsPassphrase: .needsPassphrase
        case .WrongPassphrase: .wrongPassphrase
        default: .invalidKey
        }
    }
}

/// File-scope shim: inside `KeyLibrary` the name `importKey` resolves to the method.
private func ffiImportKey(_ data: Data, _ passphrase: String?) throws -> KeyMaterial {
    try importKey(pemBytes: data, passphrase: passphrase)
}
