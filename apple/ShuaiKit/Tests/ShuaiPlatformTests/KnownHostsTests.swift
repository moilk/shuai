import Foundation
import Testing
import ShuaiCore
@testable import ShuaiPlatform

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("shuai-tests-\(UUID().uuidString)")
        .appendingPathComponent("known_hosts")
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _challenges: [HostKeyChallenge] = []
    func add(_ c: HostKeyChallenge) { lock.lock(); _challenges.append(c); lock.unlock() }
    var challenges: [HostKeyChallenge] { lock.lock(); defer { lock.unlock() }; return _challenges }
}

@Suite struct KnownHostsTests {
    @Test func missingFileIsEmptyAndAddPersists() throws {
        let url = tempFile()
        let store = KnownHostsStore(fileURL: url)
        let k = try generateKey(alg: .ed25519, comment: "")
        #expect(store.text() == "")
        #expect(try store.check(host: "h", port: 22, publicKeyLine: k.publicLine) == .unknown)
        try store.add(host: "h", port: 22, publicKeyLine: k.publicLine)
        // A fresh instance reads the file.
        let again = KnownHostsStore(fileURL: url)
        #expect(try again.check(host: "h", port: 22, publicKeyLine: k.publicLine) == .trusted)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("h ssh-ed25519 "))
    }

    @Test func tofuAsksOnceThenRemembers() async throws {
        let store = KnownHostsStore(fileURL: tempFile())
        let k = try generateKey(alg: .ed25519, comment: "")
        let seen = Counter()
        let v = TOFUVerifier(store: store) { c in seen.add(c); return true }
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: k.publicLine))
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: k.publicLine))
        #expect(seen.challenges.count == 1)
        #expect(seen.challenges[0].kind == .unknown)
        #expect(seen.challenges[0].fingerprint == k.fingerprint)
    }

    @Test func rejectedKeyIsNotStored() async throws {
        let store = KnownHostsStore(fileURL: tempFile())
        let k = try generateKey(alg: .ed25519, comment: "")
        let v = TOFUVerifier(store: store) { _ in false }
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: k.publicLine) == false)
        #expect(try store.check(host: "h", port: 22, publicKeyLine: k.publicLine) == .unknown)
    }

    @Test func changedKeyAsksWithExpectedFingerprints() async throws {
        let store = KnownHostsStore(fileURL: tempFile())
        let a = try generateKey(alg: .ed25519, comment: "")
        let b = try generateKey(alg: .ed25519, comment: "")
        try store.add(host: "h", port: 22, publicKeyLine: a.publicLine)
        let seen = Counter()
        let v = TOFUVerifier(store: store, decide: { _ in true }, decideChanged: { c in seen.add(c); return false })
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: b.publicLine) == false)
        #expect(seen.challenges[0].kind == .changed(expectedFingerprints: [a.fingerprint]))
    }

    @Test func malformedKeyLineIsRejectedWithoutAsking() async throws {
        let seen = Counter()
        let v = TOFUVerifier(store: KnownHostsStore(fileURL: tempFile())) { c in seen.add(c); return true }
        #expect(await v.verify(host: "h", port: 22, publicKeyLine: "garbage") == false)
        #expect(seen.challenges.isEmpty)
    }
}
