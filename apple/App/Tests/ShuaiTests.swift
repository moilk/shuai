import Foundation
import Testing
@testable import Shuai
import ShuaiApp
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

@MainActor @Test func startupWithSavedHostsWaitsForSelection() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("hosts.json")
    let hosts = HostStore(fileURL: file)
    let first = HostProfile(name: "First", host: "first.example.invalid", username: "alice")
    let second = HostProfile(name: "Second", host: "second.example.invalid", username: "alice")
    try hosts.add(first)
    try hosts.add(second)

    let model = AppModel(ephemeral: true, ephemeralHostsFile: file)
    #expect(model.hosts.hosts.map(\.id) == [first.id, second.id])
    #expect(model.selection == nil)
    #expect(model.preferredCompactColumn == .sidebar)
    #expect(model.sessions.existingController(for: first.id) == nil)
    #expect(model.sessions.existingController(for: second.id) == nil)
}
