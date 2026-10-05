#if os(macOS)
import Foundation
import ShuaiCore
import Testing
@testable import ShuaiApp

/// A `RemoteConnection` that runs everything on a private local tmux server (`-L shuaim4 -f /dev/null`,
/// through a `tmux` shim first on PATH), so the monitor and actions are verified against real tmux.
final class LocalTmuxConnection: RemoteConnection, @unchecked Sendable {
    static let socket = "shuaim4-\(ProcessInfo.processInfo.processIdentifier)"
    let shimDir: URL

    static var realTmux: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init?() {
        guard let tmux = Self.realTmux else { return nil }
        shimDir = FileManager.default.temporaryDirectory.appendingPathComponent("shuai-shim-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nexec \(tmux) -L \(Self.socket) -f /dev/null \"$@\"\n"
        let url = shimDir.appendingPathComponent("tmux")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func process(_ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shimDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TMUX"] = nil
        p.environment = env
        return p
    }

    /// Local shell helper for test setup.
    @discardableResult
    func sh(_ command: String) async throws -> ExecResult { try await exec(command) }

    func exec(_ command: String) async throws -> ExecResult {
        let p = process(command)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ExecResult(stdout: o, stderr: e, exitStatus: UInt32(p.terminationStatus), exitSignal: nil)
    }

    func execStream(_ command: String) async throws -> RemoteExec {
        let p = process(command)
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let (events, cont) = AsyncStream<ExecEvent>.makeStream()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { cont.yield(.stdout(bytes: d)) }
        }
        p.terminationHandler = { _ in
            out.fileHandleForReading.readabilityHandler = nil
            cont.yield(.closed(reason: .remote))
            cont.finish()
        }
        try p.run()
        return LocalExec(process: p, stdin: stdin, events: events)
    }

    func openShell(cols _: UInt32, rows _: UInt32, term _: String, env _: [FfiEnvVar]) async throws -> RemoteShell { fatalError() }
    func openPtyExec(command _: String, cols _: UInt32, rows _: UInt32, term _: String, env _: [FfiEnvVar]) async throws -> RemoteShell { fatalError() }
    func closed() async -> CloseReason { .local }
    func disconnect() async {}

    /// Starts a tmux client on a pseudo terminal (via `script`) attached to `session`; returns its process.
    func attachPtyClient(session: String) throws -> (Process, Pipe) {
        let p = process("exec script -q /dev/null tmux attach-session -t '=\(session):'")
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return (p, stdin)
    }

    func cleanup() {
        let p = process("tmux kill-server")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: shimDir)
    }
}

final class LocalExec: RemoteExec, @unchecked Sendable {
    let process: Process
    let stdin: Pipe
    let events: AsyncStream<ExecEvent>
    init(process: Process, stdin: Pipe, events: AsyncStream<ExecEvent>) {
        self.process = process
        self.stdin = stdin
        self.events = events
    }

    func writeStdin(_ data: Data) async throws { try stdin.fileHandleForWriting.write(contentsOf: data) }
    func closeStdin() async { try? stdin.fileHandleForWriting.close() }
    func close() async {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

/// Serialized: they share one tmux socket.
@MainActor
@Suite(.serialized) struct TmuxRealTests {
    struct Rig {
        let conn: LocalTmuxConnection
        let monitor: TmuxMonitor
        let actions: TmuxActions
        let dir: String
    }

    func rig(pty: Bool = false) async throws -> (Rig, [Process])? {
        guard let conn = LocalTmuxConnection() else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shuai-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = dir.resolvingSymlinksInPath().path
        try await conn.sh("tmux kill-server; tmux new-session -d -s main -x 120 -y 40 -c '\(real)'")
        var procs: [Process] = []
        if pty {
            let (p, _) = try conn.attachPtyClient(session: "main")
            procs.append(p)
            // wait for the client to show up
            for _ in 0 ..< 100 {
                let r = try await conn.sh("tmux list-clients | wc -l")
                if String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "0" { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let monitor = TmuxMonitor(sessionName: "main", ptySize: { (120, 40) })
        await monitor.start(on: conn)
        return (Rig(conn: conn, monitor: monitor, actions: TmuxActions(monitor: monitor), dir: real), procs)
    }

    func finish(_ r: Rig, _ procs: [Process]) async {
        await r.monitor.stop()
        procs.forEach { $0.terminate() }
        r.conn.cleanup()
    }

    func query(_ r: Rig, _ format: String, target: String = "") async throws -> String {
        let res = try await r.conn.sh("tmux display-message -p \(target) '\(format)'")
        return String(decoding: res.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func monitorSeesTheRealTopologyAndLiveChanges() async throws {
        guard let (r, procs) = try await rig() else { return }
        #expect(r.monitor.state == .live)
        #expect(r.monitor.topology?.sessions.first?.name == "main")
        #expect(r.monitor.topology?.sessions.first?.windows.count == 1)
        // changed behind the monitor's back: arrives through the control channel
        try await r.conn.sh("tmux new-window -t =main: -n outside")
        #expect(await waitUntil { r.monitor.topology?.sessions.first?.windows.count == 2 })
        try await r.conn.sh("tmux rename-window -t =main:outside renamed-outside")
        #expect(await waitUntil { r.monitor.topology?.sessions.first?.windows.contains { $0.name == "renamed-outside" } == true })
        await finish(r, procs)
    }

    @Test func actionsDriveRealTmux() async throws {
        guard let (r, procs) = try await rig() else { return }
        let a = r.actions
        // new window starts in the active pane's directory
        try await a.newWindow()
        #expect(await waitUntil { a.windows.count == 2 })
        let cwd = try await query(r, "#{pane_current_path}", target: "-t =main:")
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == r.dir)

        // rename (space and a leading dash survive)
        let id = try #require(a.windows.last?.id)
        try await a.renameWindow(id, to: "-my window")
        #expect(await waitUntil { a.windows.last?.name == "-my window" })

        // split both ways; new panes inherit the directory
        try await a.split(horizontal: true)
        #expect(await waitUntil { a.activeWindow?.panes.count == 2 })
        try await a.split(horizontal: false)
        #expect(await waitUntil { a.activeWindow?.panes.count == 3 })
        let panePath = try await query(r, "#{pane_current_path}", target: "-t =main:")
        #expect(URL(fileURLWithPath: panePath).resolvingSymlinksInPath().path == r.dir)

        // zoom toggles
        try await a.zoom()
        #expect(await waitUntil { a.activeWindow?.flags.contains("Z") == true })
        try await a.zoom()
        #expect(await waitUntil { a.activeWindow?.flags.contains("Z") == false })

        // navigation: position 1 is the first window; next/prev/last
        try await a.selectWindow(position: 1)
        #expect(await waitUntil { a.activeWindow?.id == a.windows.first?.id })
        try await a.nextWindow()
        #expect(await waitUntil { a.activeWindow?.id == id })
        try await a.previousWindow()
        #expect(await waitUntil { a.activeWindow?.id == a.windows.first?.id })
        try await a.lastWindow()
        #expect(await waitUntil { a.activeWindow?.id == id })

        // pane direction + select pane
        let firstPane = try #require(a.activeWindow?.panes.first?.id)
        try await a.selectPane(firstPane)
        #expect(await waitUntil { a.activePane?.id == firstPane })

        // kill asks first, then closes
        a.requestKillWindow(id)
        #expect(a.windows.count == 2)
        try await a.confirmPending()
        #expect(await waitUntil { a.windows.count == 1 })
        await finish(r, procs)
    }

    @Test func switchSessionMovesThePtyClientNotTheControlClient() async throws {
        guard let (r, procs) = try await rig(pty: true) else { return }
        try await r.conn.sh("tmux new-session -d -s other -x 100 -y 30")
        #expect(await waitUntil { r.monitor.topology?.sessions.count == 2 })
        await r.monitor.refreshNow()
        let tty = try #require(r.monitor.ptyClientTty)
        #expect(!tty.isEmpty)
        let other = try #require(r.monitor.topology?.sessions.first { $0.name == "other" })
        try await r.actions.switchSession(other.id)
        await r.monitor.refreshNow()
        #expect(r.monitor.ptyClientTty == tty)
        #expect(r.monitor.viewedSessionID == other.id)
        #expect(r.actions.viewedSession?.name == "other")
        // the real client's session
        let shown = try await r.conn.sh("tmux list-clients -F '#{client_tty} #{session_name} #{client_control_mode}'")
        let text = String(decoding: shown.stdout, as: UTF8.self)
        #expect(text.contains("\(tty) other 0"))
        #expect(text.contains(" main 1")) // the control client stayed
        await finish(r, procs)
    }

    /// The user's laptop is attached to the same session: switching must move only our client.
    @Test func switchSessionNeverMovesAnotherClientAttachedToTheSameSession() async throws {
        guard let conn = LocalTmuxConnection() else { return }
        try await conn.sh("tmux kill-server; tmux new-session -d -s main -x 120 -y 40; tmux new-session -d -s other -x 100 -y 30")
        func clientCount() async throws -> Int {
            let r = try await conn.sh("tmux list-clients -F x | wc -l")
            return Int(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        func waitClients(_ n: Int) async throws {
            for _ in 0 ..< 100 where try await clientCount() < n { try await Task.sleep(for: .milliseconds(50)) }
        }
        let (laptop, _) = try conn.attachPtyClient(session: "main")
        try await waitClients(1)
        try await Task.sleep(for: .milliseconds(1100)) // client_created has one second resolution
        let (ours, _) = try conn.attachPtyClient(session: "main")
        try await waitClients(2)
        try await Task.sleep(for: .milliseconds(1100))
        let monitor = TmuxMonitor(sessionName: "main", ptySize: { (120, 40) })
        await monitor.start(on: conn)
        let actions = TmuxActions(monitor: monitor)
        let list = try await conn.sh("tmux list-clients -F '#{client_created} #{client_tty} #{client_control_mode}'")
        let rows = String(decoding: list.stdout, as: UTF8.self).split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        let ptyRows = rows.filter { $0.count == 3 && $0[2] == "0" }.sorted { Int($0[0])! < Int($1[0])! }
        #expect(ptyRows.count == 2)
        let ourTty = try #require(ptyRows.last?[1])
        let laptopTty = try #require(ptyRows.first?[1])
        #expect(monitor.ptyClientTty == ourTty)
        let other = try #require(monitor.topology?.sessions.first { $0.name == "other" })
        try await actions.switchSession(other.id)
        let shown = try await conn.sh("tmux list-clients -F '#{client_tty} #{session_name}'")
        let text = String(decoding: shown.stdout, as: UTF8.self)
        #expect(text.contains("\(ourTty) other"))
        #expect(text.contains("\(laptopTty) main"))
        await monitor.stop()
        laptop.terminate()
        ours.terminate()
        conn.cleanup()
    }
}
#endif
