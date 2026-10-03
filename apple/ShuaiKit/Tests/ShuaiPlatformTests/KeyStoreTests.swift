import Foundation
import Security
import Testing
import ShuaiCore
@testable import ShuaiPlatform

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shuai-tests-\(UUID().uuidString)")
        .appendingPathComponent(name)
}

/// Shared behaviour every KeyStore must have.
private func exerciseStore(_ store: KeyStore) throws {
    let a = try generateKey(alg: .ed25519, comment: "a")
    let b = try generateKey(alg: .ecdsaP256, comment: "b")
    let ra = KeyRecord(id: "a", name: "Alpha", material: a, createdAt: Date(timeIntervalSince1970: 100))
    let rb = KeyRecord(id: "b", name: "Beta", material: b, createdAt: Date(timeIntervalSince1970: 50))
    #expect(try store.list().isEmpty)
    #expect(try store.loadPrivatePem(id: "a") == nil)

    try store.save(privatePem: a.privatePem, record: ra)
    try store.save(privatePem: b.privatePem, record: rb)
    #expect(try store.loadPrivatePem(id: "a") == a.privatePem)
    #expect(try store.loadPrivatePem(id: "b") == b.privatePem)
    // Oldest first.
    #expect(try store.list().map(\.id) == ["b", "a"])
    #expect(try store.list().first { $0.id == "a" }?.fingerprint == a.fingerprint)

    // Saving again replaces.
    try store.save(privatePem: b.privatePem, record: KeyRecord(id: "a", name: "Renamed", material: b, createdAt: ra.createdAt))
    #expect(try store.loadPrivatePem(id: "a") == b.privatePem)
    #expect(try store.list().first { $0.id == "a" }?.name == "Renamed")

    try store.delete(id: "a")
    #expect(try store.loadPrivatePem(id: "a") == nil)
    #expect(try store.list().map(\.id) == ["b"])
    try store.delete(id: "a") // deleting a missing key is not an error
    try store.delete(id: "b")
    #expect(try store.list().isEmpty)
}

@Suite struct KeyStoreTests {
    @Test func inMemoryStore() throws {
        try exerciseStore(InMemoryKeyStore())
    }

    @Test func metadataSurvivesReopen() throws {
        let url = tempURL("keys.json")
        let m = try generateKey(alg: .ed25519, comment: "")
        let s1 = InMemoryKeyStore(metadataURL: url)
        try s1.save(privatePem: m.privatePem, record: KeyRecord(id: "x", name: "X", material: m, createdAt: Date()))
        let s2 = InMemoryKeyStore(metadataURL: url)
        #expect(try s2.list().map(\.name) == ["X"])
    }

    @Test(.enabled(if: keychainAvailable))
    func keychainStore() throws {
        let store = KeychainKeyStore(
            service: "io.github.moilk.shuai.keys.test-\(UUID().uuidString)",
            metadataURL: tempURL("keys.json")
        )
        defer { try? store.deleteAll() }
        try exerciseStore(store)
    }
}

/// Probes whether this process may use the keychain (CI / sandboxed runners may not).
let keychainAvailable: Bool = {
    let service = "io.github.moilk.shuai.keys.probe-\(UUID().uuidString)"
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "probe",
        kSecValueData as String: Data("x".utf8),
    ]
    let st = SecItemAdd(q as CFDictionary, nil)
    SecItemDelete(q as CFDictionary)
    return st == errSecSuccess
}()
