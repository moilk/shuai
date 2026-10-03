import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform
@testable import ShuaiApp

/// Throwaway ed25519 key encrypted with passphrase "hunter2" (generated for this test only).
private let encryptedKey = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAHThVuLn
vqyq+CyquglPW/AAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJaVr4Z/Ho4GMBOY
n6LTHgrUExFAXI5HtWJ863le0oIiAAAAkL1OHcG9DqyDFk3PFlsHdb9WERjZO6MadPZKFH
pTSONEP/NbYY1EER67a/F99Ghcp7c6De4LoA0exJ6XsG9KZGx1OQOD0M7+939B2VYSg1P3
78dptQ6wQ/60AsIUpKYiJhJAFI3gmtZpHFhJY0VGIhDLAZHUpRm4SHSEARpWKy9qGSx97G
cvu9A6DnUCclm4wA==
-----END OPENSSH PRIVATE KEY-----
"""
private let encryptedFingerprint = "SHA256:47h1jAX/1T8caTrbFBelxNaAongMQWqFfhiVZLvtfZg"

@MainActor @Suite struct KeyLibraryTests {
    private func library() -> (KeyLibrary, InMemoryKeyStore) {
        let store = InMemoryKeyStore()
        return (KeyLibrary(store: store), store)
    }

    @Test func generateStoresKeyAndExposesFingerprintAndRandomart() throws {
        let (lib, store) = library()
        let item = try lib.generate(name: "ipad", algorithm: .ed25519)
        #expect(item.name == "ipad")
        #expect(item.algorithm.contains("ed25519"))
        #expect(item.fingerprint.hasPrefix("SHA256:"))
        #expect(item.randomart.contains("+---"))
        #expect(item.publicLine.hasPrefix("ssh-ed25519 "))
        #expect(lib.items.map(\.id) == [item.id])
        #expect(try store.loadPrivatePem(id: item.id)?.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") == true)
    }

    @Test func generateEcdsa() throws {
        let (lib, _) = library()
        #expect(try lib.generate(name: "e", algorithm: .ecdsaP256).publicLine.hasPrefix("ecdsa-sha2-nistp256 "))
    }

    @Test func importsPastedPlainKeyAndNormalizes() throws {
        let (lib, store) = library()
        let k = try generateKey(alg: .ed25519, comment: "")
        let item = try lib.importKey(text: "\n" + k.privatePem + "\n", name: "pasted", passphrase: nil)
        #expect(item.fingerprint == k.fingerprint)
        #expect(try store.loadPrivatePem(id: item.id) != nil)
    }

    @Test func encryptedKeyNeedsThenAcceptsPassphrase() throws {
        let (lib, store) = library()
        #expect(throws: KeyLibraryError.needsPassphrase) {
            try lib.importKey(data: Data(encryptedKey.utf8), name: "enc", passphrase: nil)
        }
        #expect(throws: KeyLibraryError.wrongPassphrase) {
            try lib.importKey(data: Data(encryptedKey.utf8), name: "enc", passphrase: "nope")
        }
        #expect(lib.items.isEmpty)
        let item = try lib.importKey(data: Data(encryptedKey.utf8), name: "enc", passphrase: "hunter2")
        #expect(item.fingerprint == encryptedFingerprint)
        // The stored PEM is decrypted (the Keychain protects it), so connecting never prompts.
        #expect(try store.loadPrivatePem(id: item.id)?.contains("bcrypt") == false)
    }

    @Test func garbageIsRejected() {
        let (lib, _) = library()
        #expect(throws: KeyLibraryError.invalidKey) {
            try lib.importKey(text: "definitely not a key", name: "x", passphrase: nil)
        }
        #expect(lib.items.isEmpty)
    }

    @Test func blankNameFallsBackToAlgorithm() throws {
        let (lib, _) = library()
        #expect(try lib.generate(name: "  ", algorithm: .ed25519).name == "ed25519 key")
    }

    @Test func deleteRemovesFromStore() throws {
        let (lib, store) = library()
        let a = try lib.generate(name: "a", algorithm: .ed25519)
        let b = try lib.generate(name: "b", algorithm: .ed25519)
        try lib.delete(id: a.id)
        #expect(lib.items.map(\.id) == [b.id])
        #expect(try store.loadPrivatePem(id: a.id) == nil)
    }

    @Test func itemsSurviveReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kl-\(UUID().uuidString)/keys.json")
        let s1 = InMemoryKeyStore(metadataURL: url)
        let item = try KeyLibrary(store: s1).generate(name: "k", algorithm: .ed25519)
        // Same Keychain (here: same in-memory store) + metadata file.
        let lib2 = KeyLibrary(store: s1)
        #expect(lib2.items.map(\.id) == [item.id])
        #expect(lib2.items[0].randomart == item.randomart)
    }

    @Test func publicKeyLineForSharing() throws {
        let (lib, _) = library()
        let item = try lib.generate(name: "a", algorithm: .ed25519)
        #expect(lib.publicKeyLine(id: item.id) == item.publicLine)
        #expect(lib.publicKeyLine(id: "missing") == nil)
    }
}

@Suite struct PasswordStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let s = InMemoryPasswordStore()
        let id = UUID()
        #expect(try s.password(for: id) == nil)
        try s.setPassword("pw", for: id)
        #expect(try s.password(for: id) == "pw")
        try s.setPassword("pw2", for: id)
        #expect(try s.password(for: id) == "pw2")
        try s.deletePassword(for: id)
        #expect(try s.password(for: id) == nil)
        try s.deletePassword(for: id) // missing is fine
    }

    @Test func keychainServiceNameIsStable() {
        #expect(KeychainPasswordStore.defaultService == "io.github.moilk.shuai.passwords")
    }
}

@MainActor @Suite struct AppSettingsTests {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "shuai-test-\(UUID().uuidString)")!
        return d
    }

    @Test func defaultsAreSensible() {
        let s = AppSettings(defaults: defaults())
        #expect(s.theme == .dark)
        #expect(s.fontSize == 14)
        #expect(s.accessoryBar == .docked)
        #expect(s.optionAsAlt)
    }

    @Test func persistsAcrossInstances() {
        let d = defaults()
        let a = AppSettings(defaults: d)
        a.theme = .light
        a.fontSize = 18
        a.accessoryBar = .floating
        a.optionAsAlt = false
        let b = AppSettings(defaults: d)
        #expect(b.theme == .light)
        #expect(b.fontSize == 18)
        #expect(b.accessoryBar == .floating)
        #expect(!b.optionAsAlt)
    }

    @Test func fontSizeIsClamped() {
        let s = AppSettings(defaults: defaults())
        s.fontSize = 1
        #expect(s.fontSize == 6)
        s.fontSize = 400
        #expect(s.fontSize == 40)
    }

    @Test func themeMapsToTerminalTheme() {
        #expect(AppSettings.Theme.dark.terminalTheme.isDark)
        #expect(!AppSettings.Theme.light.terminalTheme.isDark)
    }
}
