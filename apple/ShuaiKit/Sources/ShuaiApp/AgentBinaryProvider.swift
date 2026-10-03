import Foundation

public enum AgentBinaryError: Error, Equatable, LocalizedError {
    /// Not a triple the app ships a binary for.
    case unsupported(String)
    /// A supported triple whose binary is not bundled (run `scripts/build-agent.sh`).
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let t): "No shuai-agent build for \(t)."
        case .missing(let t): "The shuai-agent binary for \(t) is not bundled in this build (run scripts/build-agent.sh)."
        }
    }
}

public protocol AgentBinaryProviding: Sendable {
    func binary(forTriple triple: String) throws -> Data
}

/// Triples `scripts/build-agent.sh` produces.
public let supportedAgentTriples = ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"]

/// Reads `shuai-agent-<triple>` files from a directory.
public struct DirectoryAgentBinaryProvider: AgentBinaryProviding {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func binary(forTriple triple: String) throws -> Data {
        guard supportedAgentTriples.contains(triple) else { throw AgentBinaryError.unsupported(triple) }
        let url = directory.appendingPathComponent("shuai-agent-\(triple)")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw AgentBinaryError.missing(triple) }
        return data
    }
}

/// Reads the binaries the App target bundles as resources (`apple/App/Resources/agent`).
public struct BundleAgentBinaryProvider: AgentBinaryProviding {
    public let bundle: Bundle
    public init(bundle: Bundle = .main) { self.bundle = bundle }

    public func binary(forTriple triple: String) throws -> Data {
        guard supportedAgentTriples.contains(triple) else { throw AgentBinaryError.unsupported(triple) }
        let name = "shuai-agent-\(triple)"
        let url = bundle.url(forResource: name, withExtension: nil)
            ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "agent")
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw AgentBinaryError.missing(triple)
        }
        return data
    }
}
