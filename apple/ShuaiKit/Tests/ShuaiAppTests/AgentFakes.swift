import Foundation
import ShuaiCore
@testable import ShuaiApp

/// Scripted stream standing in for `shuai-agent watch`.
final class FakeAgentStream: AgentStream, @unchecked Sendable {
    let events: AsyncStream<AgentStreamEvent>
    private let continuation: AsyncStream<AgentStreamEvent>.Continuation
    let closeCalls = Locked(0)
    let command: String

    init(command: String) {
        self.command = command
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ text: String) { continuation.yield(.stdout(Data(text.utf8))) }
    func emitLines(_ lines: [String]) { emit(lines.joined(separator: "\n") + "\n") }
    func emitStderr(_ text: String) { continuation.yield(.stderr(Data(text.utf8))) }
    func exit(_ status: Int?) { continuation.yield(.exited(status)) }
    func finish() { continuation.yield(.closed); continuation.finish() }
    func close() async { closeCalls.with { $0 += 1 }; continuation.finish() }
}

struct UploadRecord: Equatable {
    var path: String
    var data: Data
    var mode: UInt32
}

/// Records everything the monitor/installer does to a host.
final class FakeAgentRemote: AgentRemote, @unchecked Sendable {
    typealias Handler = @Sendable (String) -> RemoteExecOutput
    let commands = Locked<[String]>([])
    let uploads = Locked<[UploadRecord]>([])
    let streams = Locked<[FakeAgentStream]>([])
    private let handler: Locked<Handler>
    var uploadError: Error?
    var streamError: Error?
    /// When set, `exec` waits for it before answering (for optimistic-state tests).
    let gate = Locked<(@Sendable () async -> Void)?>(nil)

    init(handler: @escaping Handler = { _ in .ok() }) { self.handler = Locked(handler) }

    func setHandler(_ h: @escaping Handler) { handler.with { $0 = h } }

    func exec(_ command: String) async throws -> RemoteExecOutput {
        commands.with { $0.append(command) }
        if let g = gate.get { await g() }
        return handler.get(command)
    }

    func execStream(_ command: String) async throws -> AgentStream {
        if let streamError { throw streamError }
        let s = FakeAgentStream(command: command)
        streams.with { $0.append(s) }
        return s
    }

    func upload(_ data: Data, to path: String, mode: UInt32) async throws {
        if let uploadError { throw uploadError }
        uploads.with { $0.append(UploadRecord(path: path, data: data, mode: mode)) }
    }

    var lastStream: FakeAgentStream? { streams.get.last }
    func ran(containing needle: String) -> [String] { commands.get.filter { $0.contains(needle) } }
}

struct FakeBinaries: AgentBinaryProviding {
    var available: Set<String> = ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"]
    func binary(forTriple triple: String) throws -> Data {
        guard available.contains(triple) else { throw AgentBinaryError.missing(triple) }
        return Data("ELF-\(triple)".utf8)
    }
}

/// The recorded real Claude Code 2.1.288 transcript (shuai-agent e2e fixture).
enum GoldenTranscript {
    static let lines: [String] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("core/shuai-agent/tests/fixtures/e2e-claude-2.1.288.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }()
    static let host = "e2e-host"
    static let sessionID = "08a5dc1c-d8a0-49d8-bce4-62a495c70dab"
    static let firstRequest = "2604cfd0b70257a07ee252c762c243d8"
    static let secondRequest = "1a23454a068676828d4d9b715ce4f480"
    static let heartbeat = #"{"type":"heartbeat"}"#
    static let caughtUp = #"{"type":"caught_up"}"#
}
