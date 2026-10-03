import Foundation
import Testing
import ShuaiCore
@testable import ShuaiApp

@Suite("AgentBinaryProvider")
struct AgentBinaryProviderTests {
    @Test func findsBinariesByTriple() throws {
        let dir = scratchURL("agent")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x86".utf8).write(to: dir.appendingPathComponent("shuai-agent-x86_64-unknown-linux-musl"))
        let p = DirectoryAgentBinaryProvider(directory: dir)
        #expect(try p.binary(forTriple: "x86_64-unknown-linux-musl") == Data("x86".utf8))
        #expect(throws: AgentBinaryError.self) { try p.binary(forTriple: "aarch64-unknown-linux-musl") }
    }

    @Test func rejectsUnknownTriplesAndTraversal() {
        let p = DirectoryAgentBinaryProvider(directory: scratchURL("none"))
        #expect(throws: AgentBinaryError.unsupported("../../etc/passwd")) {
            try p.binary(forTriple: "../../etc/passwd")
        }
        #expect(throws: AgentBinaryError.unsupported("x86_64-apple-darwin")) {
            try p.binary(forTriple: "x86_64-apple-darwin")
        }
    }

    @Test func bundleProviderReportsMissingResources() {
        let p = BundleAgentBinaryProvider(bundle: Bundle(for: BundleToken.self))
        #expect(throws: AgentBinaryError.self) { try p.binary(forTriple: "x86_64-unknown-linux-musl") }
    }
    private final class BundleToken {}
}

@Suite("ShellQuote and Codex config")
struct ShellAndCodexTests {
    @Test func quoting() {
        #expect(ShellQuote.quote("/home/u/.shuai") == "/home/u/.shuai")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("a b") == "'a b'")
    }

    @Test func setNotifyInsertsBeforeTables() {
        let out = CodexConfigEditor.settingNotify(in: "model = \"x\"\n[tui]\nfoo = 1\n", argv: ["/a/b", "codex-notify"])
        #expect(out == "notify = [\"/a/b\", \"codex-notify\"]\nmodel = \"x\"\n[tui]\nfoo = 1\n")
    }

    @Test func setNotifyOnEmptyAndEscapes() {
        #expect(CodexConfigEditor.settingNotify(in: "", argv: ["a\"b"]) == "notify = [\"a\\\"b\"]\n")
    }

    @Test func replacesSingleAndMultiLineNotify() {
        let one = CodexConfigEditor.settingNotify(in: "notify = [\"x\"]\nmodel = 1\n", argv: ["n"])
        #expect(one == "notify = [\"n\"]\nmodel = 1\n")
        let multi = CodexConfigEditor.settingNotify(in: "notify = [\n  \"x\",\n  \"y\"\n]\nmodel = 1\n", argv: ["n"])
        #expect(multi == "notify = [\"n\"]\nmodel = 1\n")
        // A `notify` key inside a table is not the top-level one.
        let table = CodexConfigEditor.settingNotify(in: "[tui]\nnotify = 1\n", argv: ["n"])
        #expect(table == "notify = [\"n\"]\n[tui]\nnotify = 1\n")
    }

    @Test func removeNotifyOnlyIfOurs() {
        let ours = "notify = [\"/h/.shuai/bin/shuai-agent\", \"codex-notify\"]\nmodel = 1\n"
        #expect(CodexConfigEditor.removingShuaiNotify(from: ours) == "model = 1\n")
        let theirs = "notify = [\"/usr/bin/other\"]\n"
        #expect(CodexConfigEditor.removingShuaiNotify(from: theirs) == theirs)
    }
}

@Suite("AttentionBannerQueue")
@MainActor
struct AttentionBannerQueueTests {
    let key = FfiSessionKey(host: "h", sessionId: "s1")
    func request(_ id: String = "r1") -> FfiPendingPermission {
        FfiPendingPermission(requestId: id, toolName: "Bash", inputPreview: "rm -rf x", toolInputJson: "{}", since: 1)
    }
    func state(_ to: FfiSessionState, from: FfiSessionState = .working(tool: nil)) -> FfiTrackerChange {
        .stateChanged(key: key, from: from, to: to)
    }

    @Test func permissionRequestsBannerOnceAndClear() {
        let q = AttentionBannerQueue()
        q.enqueue([.permissionRequested(key: key, request: request())])
        q.enqueue([.permissionRequested(key: key, request: request())])
        #expect(q.banners.count == 1)
        #expect(q.current?.kind == .permission(requestId: "r1", tool: "Bash", preview: "rm -rf x"))
        q.enqueue([.permissionCleared(key: key)])
        #expect(q.banners.isEmpty)
    }

    @Test func stateTransitionsOnly() {
        let q = AttentionBannerQueue()
        q.enqueue([state(.working(tool: "Bash"), from: .starting)])
        q.enqueue([state(.needsPermission)])
        q.enqueue([state(.ended, from: .done)])
        #expect(q.banners.isEmpty)
        q.enqueue([state(.done)])
        #expect(q.current?.kind == .done)
        q.enqueue([state(.needsInput, from: .done)])
        // The newer transition for the same session replaces the old banner.
        #expect(q.banners.count == 1)
        #expect(q.current?.kind == .needsInput)
        q.enqueue([state(.failed(error: "boom"))])
        #expect(q.current?.kind == .failed(error: "boom"))
        #expect(q.banners.count == 1)
    }

    @Test func permissionOutranksOthersAndDismiss() {
        let q = AttentionBannerQueue()
        let other = FfiSessionKey(host: "h", sessionId: "s2")
        q.enqueue([.stateChanged(key: other, from: .working(tool: nil), to: .done)])
        q.enqueue([.permissionRequested(key: key, request: request())])
        #expect(q.current?.key == key)
        let id = q.current!.id
        q.dismiss(id)
        #expect(q.current?.key == other)
        #expect(q.banners.count == 1)
    }

    @Test func suppressedAndCapacity() {
        let q = AttentionBannerQueue(capacity: 2, isSuppressed: { $0.sessionId == "quiet" })
        q.enqueue([.stateChanged(key: FfiSessionKey(host: "h", sessionId: "quiet"), from: .starting, to: .done)])
        #expect(q.banners.isEmpty)
        for i in 0..<4 {
            q.enqueue([.stateChanged(key: FfiSessionKey(host: "h", sessionId: "s\(i)"), from: .starting, to: .done)])
        }
        #expect(q.banners.count == 2)
        #expect(Set(q.banners.map(\.key.sessionId)) == ["s2", "s3"])
    }

    @Test func removedSessionDropsItsBanner() {
        let q = AttentionBannerQueue()
        q.enqueue([state(.done)])
        q.enqueue([.sessionRemoved(key: key)])
        #expect(q.banners.isEmpty)
    }
}

@Suite("PermissionPreview")
struct PermissionPreviewTests {
    @Test func bashShowsCommand() {
        let p = PermissionPreview.make(toolName: "Bash", inputJSON: #"{"command":"touch e2e_ok.txt","description":"d"}"#)
        #expect(p.kind == .command)
        #expect(p.primary == "touch e2e_ok.txt")
    }

    @Test func editShowsPathAndDiffLines() {
        let p = PermissionPreview.make(
            toolName: "Edit",
            inputJSON: #"{"file_path":"/w/a.swift","old_string":"let a = 1\nlet b = 2","new_string":"let a = 3"}"#)
        #expect(p.kind == .edit)
        #expect(p.primary == "/w/a.swift")
        #expect(p.diff == [.removed("let a = 1"), .removed("let b = 2"), .added("let a = 3")])
    }

    @Test func writeShowsPathAndAddedLines() {
        let p = PermissionPreview.make(toolName: "Write", inputJSON: #"{"file_path":"/w/x","content":"a\nb"}"#)
        #expect(p.kind == .write)
        #expect(p.diff == [.added("a"), .added("b")])
    }

    @Test func diffIsTruncated() {
        let big = (0..<500).map { "l\($0)" }.joined(separator: "\n")
        let p = PermissionPreview.make(toolName: "Write", inputJSON: "{\"file_path\":\"/x\",\"content\":\"\(big)\"}".replacingOccurrences(of: "\n", with: "\\n"))
        #expect(p.diff.count <= PermissionPreview.maxDiffLines + 1)
        #expect(p.truncated)
    }

    @Test func hugeInputsAreCapped() {
        let huge = String(repeating: "x", count: 2_000_000)
        let cmd = PermissionPreview.make(toolName: "Bash", inputJSON: "{\"command\":\"\(huge)\"}")
        #expect(cmd.kind == .command)
        #expect(cmd.primary.count <= PermissionPreview.maxPrimaryChars + 1)
        #expect(cmd.truncated)

        let write = PermissionPreview.make(toolName: "Write", inputJSON: "{\"file_path\":\"/x\",\"content\":\"\(huge)\"}")
        #expect(write.diff.allSatisfy { if case .added(let s) = $0 { s.count <= PermissionPreview.maxLineChars + 1 } else { false } })
        #expect(write.truncated)

        let other = PermissionPreview.make(toolName: "Mcp", inputJSON: "{\"a\":\"\(huge)\"}")
        #expect(other.primary.count <= PermissionPreview.maxPrimaryChars + 1)
        let bad = PermissionPreview.make(toolName: "Bash", inputJSON: huge)
        #expect(bad.primary.count <= PermissionPreview.maxPrimaryChars + 1)
    }

    @Test func otherToolsAndBadJSONFallBack() {
        let p = PermissionPreview.make(toolName: "WebFetch", inputJSON: #"{"url":"https://x.dev"}"#)
        #expect(p.kind == .other)
        #expect(p.primary.contains("https://x.dev"))
        let bad = PermissionPreview.make(toolName: "Bash", inputJSON: "nope")
        #expect(bad.kind == .other)
        #expect(bad.primary == "nope")
    }
}
