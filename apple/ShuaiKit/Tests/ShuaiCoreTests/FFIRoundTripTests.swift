import Foundation
import Testing
@testable import ShuaiCore

@Suite struct KeysFFITests {
    @Test func generateAndInspect() throws {
        let k = try generateKey(alg: .ed25519, comment: "ipad")
        #expect(k.privatePem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(k.publicLine.hasPrefix("ssh-ed25519 "))
        #expect(k.fingerprint.hasPrefix("SHA256:"))
        let info = try publicInfo(privatePem: k.privatePem)
        #expect(info.fingerprint == k.fingerprint)
        #expect(try publicKeyFingerprint(publicKeyLine: k.publicLine) == k.fingerprint)
    }

    @Test func importNormalisesAndReportsErrors() throws {
        let k = try generateKey(alg: .ecdsaP256, comment: "")
        let imported = try importKey(pemBytes: Data(k.privatePem.utf8), passphrase: nil)
        #expect(imported.fingerprint == k.fingerprint)
        #expect(throws: FfiKeyError.malformed) {
            try importKey(pemBytes: Data("nope".utf8), passphrase: nil)
        }
    }

    @Test func knownHostsTofu() throws {
        let a = try generateKey(alg: .ed25519, comment: "a")
        let b = try generateKey(alg: .ed25519, comment: "b")
        #expect(try knownHostsCheck(text: "", host: "h", port: 22, publicKeyLine: a.publicLine) == .unknown)
        let text = try knownHostsAdd(text: "", host: "h", port: 22, publicKeyLine: a.publicLine, hashed: false)
        #expect(try knownHostsCheck(text: text, host: "h", port: 22, publicKeyLine: a.publicLine) == .trusted)
        let st = try knownHostsCheck(text: text, host: "h", port: 22, publicKeyLine: b.publicLine)
        #expect(st == .mismatch(expectedFingerprints: [a.fingerprint]))
    }
}

@Suite struct TmuxFFITests {
    @Test func parseTopology() throws {
        let us = "\u{1f}"
        let line = ["$0", "main", "1", "@1", "0", "zsh", "1", "*", "%1", "0", "1", "claude", "/home/u", "123", "/dev/pts/1", "t", "80", "24"]
            .joined(separator: us)
        let t = try parseTopology(line + "\n")
        #expect(t.sessions.count == 1)
        #expect(t.sessions[0].windows[0].panes[0].id == "%1")
        #expect(t.sessions[0].windows[0].panes[0].currentCommand == "claude")
    }

    @Test func buildersAndErrors() throws {
        let c = try tmuxSelectWindow(windowId: "@3")
        #expect(c.shell == "tmux select-window -t @3")
        #expect(throws: FfiTmuxError.self) { try tmuxSelectWindow(windowId: "3") }
    }

    @Test func controller() throws {
        let c = try TmuxController(session: "main", versionOutput: "tmux 3.4")
        #expect(c.attachCommand().shell.hasPrefix("tmux -C attach-session"))
        let sent = c.send(command: tmuxListPanesAll())
        #expect(sent.line.hasPrefix("list-panes"))
        #expect(c.push(data: Data("%window-add @5\n".utf8)) == [.needsRefresh])
    }
}

@Suite struct ReconnectFFITests {
    @Test func backoffSchedule() {
        let p = ReconnectPolicy(maxAttempts: nil, jitter: false)
        #expect(p.transition(event: .connect) == .startConnect)
        #expect(p.transition(event: .connectFailed(kind: .network)) == .scheduleRetry(delayMs: 1000))
        #expect(p.transition(event: .backoffElapsed) == .startConnect)
        #expect(p.transition(event: .connectFailed(kind: .network)) == .scheduleRetry(delayMs: 2000))
        #expect(p.transition(event: .connectFailed(kind: .authFailed)) == .none)
        #expect(p.state() == .gaveUp)
    }
}
