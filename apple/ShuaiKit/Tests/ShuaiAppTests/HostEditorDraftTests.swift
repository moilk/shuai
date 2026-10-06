import Foundation
import Testing
@testable import ShuaiApp

@Suite("HostEditorDraft")
struct HostEditorDraftTests {
    private func valid() -> HostEditorDraft {
        var d = HostEditorDraft(new: [])
        d.name = "box"
        d.host = "example.invalid"
        d.username = "dev"
        return d
    }

    @Test func messagesMatchTheEditorCopy() {
        #expect(HostValidationError.name.message == "Enter a name.")
        #expect(HostValidationError.host.message == "Enter a host name or IP address without spaces.")
        #expect(HostValidationError.port.message == "Port must be 1–65535.")
        #expect(HostValidationError.username.message == "Enter a username.")
        #expect(HostValidationError.key.message == "Choose a key.")
        #expect(HostValidationError.tmuxSessionName.message == "Enter a name without spaces at the ends, ':' or '.'.")
    }

    @Test func errorHiddenUntilTouched() {
        let v = HostEditorValidation()
        let d = HostEditorDraft(new: [])
        #expect(v.visibleMessage(for: .name, in: d) == nil)
    }

    @Test func blurRevealsThatFieldOnly() {
        var v = HostEditorValidation()
        let d = HostEditorDraft(new: [])
        v.blur(.name)
        #expect(v.visibleMessage(for: .name, in: d) == "Enter a name.")
        #expect(v.visibleMessage(for: .host, in: d) == nil)
    }

    @Test func attemptedSaveRevealsAllAndReturnsFirstField() {
        var v = HostEditorValidation()
        let d = HostEditorDraft(new: [])
        #expect(v.attemptSave(d) == .name)
        #expect(v.attemptedSave)
        #expect(v.visibleMessage(for: .host, in: d) != nil)
        #expect(v.visibleMessage(for: .username, in: d) != nil)

        var second = HostEditorValidation()
        var d2 = d
        d2.name = "box"
        #expect(second.attemptSave(d2) == .host)

        var ok = HostEditorValidation()
        #expect(ok.attemptSave(valid()) == nil)
    }

    @Test func fixedFieldHidesItsErrorImmediately() {
        var v = HostEditorValidation()
        var d = HostEditorDraft(new: [])
        _ = v.attemptSave(d)
        d.name = "box"
        #expect(v.visibleMessage(for: .name, in: d) == nil)
        #expect(v.visibleMessage(for: .host, in: d) != nil)
    }

    @Test func portRejectsNonNumericAndOutOfRange() {
        for bad in ["", "abc", "0", "65536", "-1", "22.5", "+22", " ", "٢٢"] {
            var d = valid()
            d.portText = bad
            #expect(d.errors.contains(.port), "\(bad)")
        }
        for good in ["1", "22", "65535", " 2222 "] {
            var d = valid()
            d.portText = good
            #expect(!d.errors.contains(.port), "\(good)")
        }
    }

    @Test func draftRoundTripsAProfile() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let p = HostProfile(
            id: id, name: "box", host: "example.invalid", port: 2222, username: "dev", auth: .key(keyID: "k1"),
            tmux: TmuxPrefs(enabled: false, sessionName: "work"), startupCommand: "htop", lastConnectedAt: date)
        let d = HostEditorDraft(editing: p)
        #expect(d.portText == "2222")
        #expect(d.authKind == .key)
        #expect(d.keyID == "k1")
        #expect(d.profile(id: id, lastConnectedAt: date) == p)

        var padded = d
        padded.name = "  box \n"
        padded.host = " example.invalid "
        padded.username = " dev "
        padded.startup = "  \n"
        let q = padded.profile(id: id, lastConnectedAt: nil)
        #expect(q.name == "box" && q.host == "example.invalid" && q.username == "dev")
        #expect(q.startupCommand == nil)
        #expect(q.lastConnectedAt == nil)
    }

    @Test func editDraftIsCleanUntilChanged() {
        let p = HostProfile(name: "box", host: "example.invalid", username: "dev")
        let initial = HostEditorDraft(editing: p)
        #expect(!HostEditorDirty.needsConfirmation(initial: initial, current: initial, passwordTyped: false))
        var changed = initial
        changed.name = "other"
        #expect(HostEditorDirty.needsConfirmation(initial: initial, current: changed, passwordTyped: false))
    }

    @Test func typedPasswordMakesItDirty() {
        let d = HostEditorDraft(new: [])
        #expect(HostEditorDirty.needsConfirmation(initial: d, current: d, passwordTyped: true))
    }

    @Test func newKeyAdoptedOnlyWhenNoneChosen() {
        var d = HostEditorDraft(new: [])
        d.authKind = .key
        #expect(d.adoptingNewKey(before: [], after: ["k1"]).keyID == "k1")
        #expect(d.adoptingNewKey(before: ["a"], after: ["a", "k2"]).keyID == "k2")
        #expect(d.adoptingNewKey(before: ["a"], after: ["a"]).keyID == "")
        d.keyID = "a"
        #expect(d.adoptingNewKey(before: ["a"], after: ["a", "k2"]).keyID == "a")
    }

    @Test func newKeyNotAdoptedWhenAuthIsPassword() {
        var d = HostEditorDraft(new: [])
        d.authKind = .password
        #expect(d.adoptingNewKey(before: [], after: ["k1"]).keyID == "")
        d.authKind = .ask
        #expect(d.adoptingNewKey(before: [], after: ["k1"]).keyID == "")
    }

    @Test func keyIDIgnoredByDirtyWhenAuthIsNotKey() {
        let initial = HostEditorDraft(new: [])
        var d = initial
        d.keyID = "stale"
        #expect(!HostEditorDirty.needsConfirmation(initial: initial, current: d, passwordTyped: false))
        d.authKind = .key
        #expect(HostEditorDirty.needsConfirmation(initial: initial, current: d, passwordTyped: false))
    }

    @Test func tmuxNameEdgeCasesAreInvalid() {
        for bad in ["", " work", "work ", "a:b", "a.b"] {
            var d = valid()
            d.tmuxName = bad
            #expect(d.errors.contains(.tmuxSessionName), "\(bad)")
        }
    }

    @Test func defaultAuthPrefersKeyWhenKeysExist() {
        let (kind, id) = HostEditorDraft.defaultAuth(keyIDs: ["a", "b"])
        #expect(kind == .key)
        #expect(id == "")
    }

    @Test func defaultAuthSingleKeyIsPreselected() {
        let (kind, id) = HostEditorDraft.defaultAuth(keyIDs: ["only"])
        #expect(kind == .key)
        #expect(id == "only")
        #expect(HostEditorDraft(new: ["only"]).keyID == "only")
    }

    @Test func defaultAuthWithoutKeysIsAsk() {
        let (kind, id) = HostEditorDraft.defaultAuth(keyIDs: [])
        #expect(kind == .ask)
        #expect(id == "")
    }

    private struct Leaky: Error, CustomStringConvertible {
        var description: String { "SECRET-DETAIL /private/path" }
    }

    @Test func saveErrorNeverContainsTheUnderlyingDescription() {
        let errors: [Error] = [
            HostStoreError.io("SECRET-DETAIL /private/path"), HostStoreError.corrupt,
            HostStoreError.notFound, HostStoreError.newerSchema(4711), Leaky(),
            PasswordStoreError(status: -25299),
        ]
        for e in errors {
            for saved in [false, true] {
                let m = HostEditorSaveError.message(for: e, hostSaved: saved)
                #expect(!m.isEmpty)
                #expect(!m.contains("SECRET-DETAIL"))
                #expect(!m.contains("/private"))
                #expect(!m.contains("-25299"))
                #expect(!m.contains("4711"))
            }
        }
        #expect(HostEditorSaveError.message(for: HostStoreError.io("x"), hostSaved: false)
            == "Could not save the host. Check that the storage is writable and try again.")
    }

    @Test func saveErrorForKeychainFailureSaysHostSaved() {
        let m = HostEditorSaveError.message(for: PasswordStoreError(status: -1), hostSaved: true)
        #expect(m == "Host saved, but the password could not be stored in the Keychain.")
    }
}
