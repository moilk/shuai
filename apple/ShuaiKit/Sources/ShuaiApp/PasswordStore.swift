import Foundation
import Security

/// Stored SSH passwords, one per host profile id.
public protocol PasswordStore: Sendable {
    func password(for host: UUID) throws -> String?
    func setPassword(_ password: String, for host: UUID) throws
    func deletePassword(for host: UUID) throws
}

public struct PasswordStoreError: Error, Equatable, Sendable { public var status: Int32 }

public final class InMemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: String] = [:]
    public init() {}
    public func password(for host: UUID) throws -> String? { lock.lock(); defer { lock.unlock() }; return items[host] }
    public func setPassword(_ password: String, for host: UUID) throws { lock.lock(); items[host] = password; lock.unlock() }
    public func deletePassword(for host: UUID) throws { lock.lock(); items[host] = nil; lock.unlock() }
}

/// Keychain generic passwords (`account` = host id), this device only, after first unlock.
public final class KeychainPasswordStore: PasswordStore, @unchecked Sendable {
    public static let defaultService = ShuaiAppInfo.passwordsService
    private let service: String

    public init(service: String = KeychainPasswordStore.defaultService) { self.service = service }

    private func query(_ host: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.uuidString,
        ]
    }

    public func password(for host: UUID) throws -> String? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw PasswordStoreError(status: st) }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPassword(_ password: String, for host: UUID) throws {
        try deletePassword(for: host)
        var q = query(host)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw PasswordStoreError(status: st) }
    }

    public func deletePassword(for host: UUID) throws {
        let st = SecItemDelete(query(host) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw PasswordStoreError(status: st) }
    }
}
