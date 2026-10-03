import Foundation
import Security

/// Keychain-backed key store: one generic-password item per key (`account` = key id) holding
/// the OpenSSH PEM, accessible after first unlock and (unless `synchronizable`) never leaving
/// this device. Metadata lives in a JSON file next to the app's data (it is not secret).
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public static let defaultService = "io.github.moilk.shuai.keys"

    private let service: String
    private let synchronizable: Bool
    private let metadata: KeyMetadata

    /// - Parameters:
    ///   - synchronizable: sync through iCloud Keychain. This drops the `ThisDeviceOnly`
    ///     accessibility class, which iCloud Keychain does not allow.
    public init(
        service: String = KeychainKeyStore.defaultService,
        synchronizable: Bool = false,
        metadataURL: URL? = nil
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.metadata = KeyMetadata(url: metadataURL ?? KeyMetadata.defaultURL())
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func save(privatePem: String, record: KeyRecord) throws {
        // Replace atomically enough for our purposes: delete then add.
        try deleteItem(id: record.id)
        var q = baseQuery(account: record.id)
        q[kSecValueData as String] = Data(privatePem.utf8)
        q[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "shuai key \(record.name)"
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw KeyStoreError.keychain(st) }
        try metadata.upsert(record)
    }

    public func loadPrivatePem(id: String) throws -> String? {
        var q = baseQuery(account: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw KeyStoreError.keychain(st) }
        guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { throw KeyStoreError.corrupt }
        return s
    }

    public func delete(id: String) throws {
        try deleteItem(id: id)
        try metadata.remove(id: id)
    }

    public func list() throws -> [KeyRecord] { metadata.all() }

    /// Removes every item of this service (used by tests and "reset app").
    public func deleteAll() throws {
        let st = SecItemDelete(baseQuery() as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeyStoreError.keychain(st) }
        for r in metadata.all() { try metadata.remove(id: r.id) }
    }

    private func deleteItem(id: String) throws {
        let st = SecItemDelete(baseQuery(account: id) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw KeyStoreError.keychain(st) }
    }
}
