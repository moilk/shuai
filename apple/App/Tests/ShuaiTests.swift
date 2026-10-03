import Foundation
import Testing
import ShuaiCore
import ShuaiPlatform

@Test func coreIsLinkedAndPings() {
    #expect(ShuaiCore.ping() == "pong")
}

@Test func platformAdaptersWorkOnDevice() throws {
    // Exercises ShuaiPlatform (Swift 6) + the Rust key/known_hosts code on the iOS simulator.
    let key = try generateKey(alg: .ed25519, comment: "ipad")
    let store = InMemoryKeyStore()
    try store.save(privatePem: key.privatePem, record: KeyRecord(id: "k", name: "K", material: key))
    #expect(try store.loadPrivatePem(id: "k") == key.privatePem)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString)")
    let hosts = KnownHostsStore(fileURL: url)
    #expect(try hosts.check(host: "h", port: 22, publicKeyLine: key.publicLine) == .unknown)
    try hosts.add(host: "h", port: 22, publicKeyLine: key.publicLine)
    #expect(try hosts.check(host: "h", port: 22, publicKeyLine: key.publicLine) == .trusted)
}
