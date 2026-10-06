import Foundation
import Testing
@testable import ShuaiApp

@Suite("HostEditorSave")
struct HostEditorSaveTests {
    private final class Recorder {
        var hostWrites: [(UUID, HostEditorSave.Step)] = []
        var passwordWrites: [UUID] = []
        var passwordDeletes: [UUID] = []
        var failHost: Error?
        var failPassword: Error?

        func run(_ save: inout HostEditorSave, _ draft: HostEditorDraft, password: String = "") -> HostEditorSave.Result {
            save.attempt(
                draft, password: password, lastConnectedAt: nil,
                writeHost: { p, step in
                    if let e = self.failHost { throw e }
                    self.hostWrites.append((p.id, step))
                },
                setPassword: { _, id in
                    if let e = self.failPassword { throw e }
                    self.passwordWrites.append(id)
                },
                deletePassword: { self.passwordDeletes.append($0) })
        }
    }

    private func passwordDraft() -> HostEditorDraft {
        var d = HostEditorDraft(new: [])
        d.name = "box"
        d.host = "example.invalid"
        d.username = "dev"
        d.authKind = .password
        return d
    }

    @Test func retryAfterKeychainFailureUpdatesTheSameHost() {
        let r = Recorder()
        var save = HostEditorSave(new: [])
        let id = save.id
        r.failPassword = PasswordStoreError(status: -1)
        let first = r.run(&save, passwordDraft(), password: "pw")
        #expect(first == .failed(message: "Host saved, but the password could not be stored in the Keychain."))
        r.failPassword = nil
        guard case .saved(let p) = r.run(&save, passwordDraft(), password: "pw") else {
            Issue.record("retry should save")
            return
        }
        #expect(p.id == id)
        #expect(r.hostWrites.map(\.1) == [.add, .update])
        #expect(r.hostWrites.allSatisfy { $0.0 == id })
        #expect(r.passwordWrites == [id])
    }

    @Test func retryUsesTheSameIDAcrossRebuilds() {
        // The view keeps its save state in `@State`, so a rebuilt view value reuses it; the model
        // is the same value carried across attempts.
        let r = Recorder()
        var save = HostEditorSave(new: ["k"])
        let carried = save
        r.failPassword = PasswordStoreError(status: -1)
        _ = r.run(&save, passwordDraft(), password: "pw")
        #expect(save.id == carried.id)
        #expect(save.initial == carried.initial)
        #expect(save.persisted)
        r.failPassword = nil
        _ = r.run(&save, passwordDraft(), password: "pw")
        #expect(Set(r.hostWrites.map(\.0)) == [carried.id])
    }

    @Test func switchingToKeyAuthOnRetryDeletesThePassword() {
        let r = Recorder()
        var save = HostEditorSave(new: [])
        r.failPassword = PasswordStoreError(status: -1)
        _ = r.run(&save, passwordDraft(), password: "pw")
        var d = passwordDraft()
        d.authKind = .key
        d.keyID = "k1"
        guard case .saved = r.run(&save, d, password: "pw") else {
            Issue.record("retry should save")
            return
        }
        #expect(r.passwordDeletes == [save.id])
        #expect(r.passwordWrites.isEmpty)
    }

    @Test func newHostInitialSnapshotIsStable() {
        let save = HostEditorSave(new: [])
        var d = save.initial
        d = d.adoptingNewKey(before: [], after: ["k1"])
        #expect(save.initial == HostEditorDraft(new: []))
        d.authKind = .key
        #expect(HostEditorDirty.needsConfirmation(initial: save.initial, current: d, passwordTyped: false))
    }

    @Test func editingStartsPersistedAndUpdates() {
        let p = HostProfile(name: "box", host: "example.invalid", username: "dev")
        let r = Recorder()
        var save = HostEditorSave(editing: p)
        #expect(save.id == p.id)
        _ = r.run(&save, HostEditorDraft(editing: p))
        #expect(r.hostWrites.map(\.1) == [.update])
    }

    @Test func retryWithIOErrorDoesNotClaimTheHostWasSaved() {
        let r = Recorder()
        var save = HostEditorSave(new: [])
        r.failPassword = PasswordStoreError(status: -1)
        _ = r.run(&save, passwordDraft(), password: "pw")
        r.failHost = HostStoreError.io("detail")
        let second = r.run(&save, passwordDraft(), password: "pw")
        #expect(second == .failed(message: "Could not save the host. Check that the storage is writable and try again."))
    }

    @Test func keychainFailureAfterFreshWriteSaysHostSaved() {
        let r = Recorder()
        var save = HostEditorSave(new: [])
        r.failPassword = PasswordStoreError(status: -1)
        _ = r.run(&save, passwordDraft(), password: "pw")
        let second = r.run(&save, passwordDraft(), password: "pw")
        #expect(second == .failed(message: "Host saved, but the password could not be stored in the Keychain."))
    }

    @Test func failedFirstWriteStaysUnpersisted() {
        let r = Recorder()
        var save = HostEditorSave(new: [])
        r.failHost = HostStoreError.corrupt
        _ = r.run(&save, passwordDraft())
        #expect(!save.persisted)
        r.failHost = nil
        _ = r.run(&save, passwordDraft())
        #expect(r.hostWrites.map(\.1) == [.add])
    }
}
