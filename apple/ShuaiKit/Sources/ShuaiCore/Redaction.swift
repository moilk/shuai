import Foundation

// Secrets must never reach logs: the generated records print every field by default, so give
// the sensitive ones a redacting description (used by `print`, string interpolation, etc.).

extension KeyMaterial: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "KeyMaterial(privatePem: <redacted>, publicLine: \(publicLine), fingerprint: \(fingerprint), algorithm: \(algorithm))"
    }
    public var debugDescription: String { description }
}

extension FfiAuth: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .password: return "FfiAuth.password(<redacted>)"
        case .privateKeyPem: return "FfiAuth.privateKeyPem(<redacted>)"
        case .signer: return "FfiAuth.signer"
        case .keyboardInteractive: return "FfiAuth.keyboardInteractive"
        }
    }
    public var debugDescription: String { description }
}

extension FfiConnectConfig: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "FfiConnectConfig(host: \(host), port: \(port), username: \(username), auth: \(auth), keepaliveSecs: \(keepaliveSecs))"
    }
    public var debugDescription: String { description }
}
