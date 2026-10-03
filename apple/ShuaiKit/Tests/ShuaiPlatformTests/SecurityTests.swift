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

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    private var _challenges: [HostKeyChallenge] = []
    func add(_ c: HostKeyChallenge) { lock.lock(); _n += 1; _challenges.append(c); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _n }
    var challenges: [HostKeyChallenge] { lock.lock(); defer { lock.unlock() }; return _challenges }
}

@Suite struct TOFUSecurityTests {
    @Test func changedKeyIsRejectedByDefaultEvenIfTheUnknownPromptWouldAccept() async throws {
        let url = tempURL("known_hosts")
        let store = KnownHostsStore(fileURL: url)
        let a = try generateKey(alg: .ed25519, comment: "")
        let b = try generateKey(alg: .ed25519, comment: "")
        try store.add(host: "h", port: 22, publicKeyLine: a.publicLine)
        let before = store.text()
        let asked = Calls()
        // `decide` says yes to everything; it must only ever see *unknown* hosts.
        let v = TOFUVerifier(store: store) { c in asked.add(c); return true }
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: b.publicLine) == false)
        #expect(asked.count == 0)
        #expect(store.text() == before, "a rejected changed key must not be recorded")
        #expect(try store.check(host: "h", port: 22, publicKeyLine: b.publicLine) != .trusted)
    }

    @Test func changedKeyChallengeSurfacesBothFingerprints() async throws {
        let store = KnownHostsStore(fileURL: tempURL("known_hosts"))
        let a = try generateKey(alg: .ed25519, comment: "")
        let b = try generateKey(alg: .ed25519, comment: "")
        try store.add(host: "h", port: 22, publicKeyLine: a.publicLine)
        let changed = Calls()
        let v = TOFUVerifier(store: store, decide: { _ in true }, decideChanged: { c in changed.add(c); return false })
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: b.publicLine) == false)
        let c = try #require(changed.challenges.first)
        #expect(c.fingerprint == b.fingerprint)
        #expect(c.kind == .changed(expectedFingerprints: [a.fingerprint]))
    }

    @Test func changedKeyCanBeAcceptedOnlyThroughTheExplicitChangedHandler() async throws {
        let store = KnownHostsStore(fileURL: tempURL("known_hosts"))
        let a = try generateKey(alg: .ed25519, comment: "")
        let b = try generateKey(alg: .ed25519, comment: "")
        try store.add(host: "h", port: 22, publicKeyLine: a.publicLine)
        let v = TOFUVerifier(store: store, decide: { _ in false }, decideChanged: { _ in true })
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: b.publicLine))
        // Accepting a changed key replaces the old one: the old key is no longer trusted.
        #expect(try store.check(host: "h", port: 22, publicKeyLine: b.publicLine) == .trusted)
        #expect(try store.check(host: "h", port: 22, publicKeyLine: a.publicLine) != .trusted)
    }
}

@Suite struct KeychainAttributeTests {
    private func attributes(service: String, account: String) throws -> [String: Any] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
        return try #require(out as? [String: Any])
    }

    @Test(.enabled(if: keychainAvailable))
    func defaultItemsAreThisDeviceOnlyAndNotSynchronizable() throws {
        let service = "io.github.moilk.shuai.keys.test-\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service, metadataURL: tempURL("keys.json"))
        defer { try? store.deleteAll() }
        let k = try generateKey(alg: .ed25519, comment: "")
        try store.save(privatePem: k.privatePem, record: KeyRecord(id: "k", name: "K", material: k, createdAt: Date()))
        let attrs = try attributes(service: service, account: "k")
        // The macOS file-based keychain (swift test host) does not report accessibility back;
        // iOS does. Whenever it is reported it must be the ThisDeviceOnly class.
        if let accessible = attrs[kSecAttrAccessible as String] as? String {
            #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
        let sync = attrs[kSecAttrSynchronizable as String]
        #expect(sync == nil || (sync as? NSNumber)?.boolValue == false)
    }

    @Test func addQueryIsAfterFirstUnlockThisDeviceOnlyAndNotSynchronizableByDefault() throws {
        let k = try generateKey(alg: .ed25519, comment: "")
        let record = KeyRecord(id: "k", name: "K", material: k, createdAt: Date())
        let store = KeychainKeyStore(service: "s", metadataURL: tempURL("keys.json"))
        let q = store.addQuery(privatePem: k.privatePem, record: record)
        #expect(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test func synchronizableIsOptInAndDropsThisDeviceOnly() throws {
        let k = try generateKey(alg: .ed25519, comment: "")
        let record = KeyRecord(id: "k", name: "K", material: k, createdAt: Date())
        let store = KeychainKeyStore(service: "s", synchronizable: true, metadataURL: tempURL("keys.json"))
        let q = store.addQuery(privatePem: k.privatePem, record: record)
        #expect(q[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func publicDescriptionsNeverContainThePem() throws {
        let k = try generateKey(alg: .ed25519, comment: "")
        let record = KeyRecord(id: "k", name: "K", material: k, createdAt: Date())
        #expect(!"\(record)".contains("PRIVATE KEY"))
        #expect(!"\(k)".contains("PRIVATE KEY"), "KeyMaterial must redact its PEM when printed")
    }
}
