import Foundation
import Observation
import Security

public enum PushSecretKey: String, Sendable { case topic, token }

/// Where the topic and the access token live (Keychain in the app): on the public server the
/// topic is the only thing keeping strangers from reading the (status-only) pushes.
public protocol PushSecretStore: Sendable {
    func get(_ key: PushSecretKey) -> String?
    func set(_ value: String?, for key: PushSecretKey)
}

public final class InMemoryPushSecretStore: PushSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PushSecretKey: String] = [:]
    public init() {}
    public func get(_ key: PushSecretKey) -> String? { lock.lock(); defer { lock.unlock() }; return items[key] }
    public func set(_ value: String?, for key: PushSecretKey) { lock.lock(); items[key] = value; lock.unlock() }
}

/// Keychain generic passwords, this device only, after first unlock.
public final class KeychainPushSecretStore: PushSecretStore, @unchecked Sendable {
    public static let defaultService = "io.github.moilk.shuai.push"
    private let service: String
    public init(service: String = KeychainPushSecretStore.defaultService) { self.service = service }

    private func query(_ key: PushSecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key.rawValue]
    }

    public func get(_ key: PushSecretKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func set(_ value: String?, for key: PushSecretKey) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

public enum PushTestResult: Equatable, Sendable {
    case sent
    case failed(String)
}

/// Background push settings (ntfy). Defaults: off, the public ntfy.sh server and a random private topic.
@MainActor @Observable
public final class PushSettings {
    public static let defaultServer = "https://ntfy.sh"
    /// The official ntfy iOS app (shows the pushes).
    public static let appStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!

    public var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }
    public var serverText: String { didSet { defaults.set(serverText, forKey: Keys.server) } }
    public private(set) var topic: String
    public var token: String {
        didSet { secrets.set(token.isEmpty ? nil : token, for: .token) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: PushSecretStore
    @ObservationIgnored private let transport: NtfyTransport

    private enum Keys {
        static let enabled = "pushEnabled"
        static let server = "pushServer"
    }

    public init(
        defaults: UserDefaults = .standard, secrets: PushSecretStore = KeychainPushSecretStore(),
        transport: NtfyTransport = URLSessionNtfyTransport(), randomBytes: (Int) -> [UInt8] = NtfyTopic.secureRandom
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.transport = transport
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        serverText = defaults.string(forKey: Keys.server) ?? Self.defaultServer
        token = secrets.get(.token) ?? ""
        if let t = secrets.get(.topic), NtfyTopic.isValid(t) {
            topic = t
        } else {
            let t = NtfyTopic.generate(randomBytes: randomBytes)
            secrets.set(t, for: .topic)
            topic = t
        }
    }

    public func regenerateTopic(randomBytes: (Int) -> [UInt8] = NtfyTopic.secureRandom) {
        let t = NtfyTopic.generate(randomBytes: randomBytes)
        secrets.set(t, for: .topic)
        topic = t
    }

    public var serverValidation: NtfyServer.Validation { NtfyServer.validate(serverText) }

    public var serverWarning: String? {
        if case .insecure = serverValidation { NtfyServer.insecureWarning } else { nil }
    }

    /// What goes into the host's `[ntfy]` section; nil while push is off or the server is invalid.
    public var config: NtfyConfig? {
        guard enabled, let url = serverValidation.url else { return nil }
        return NtfyConfig(server: url.absoluteString, topic: topic, token: token.isEmpty ? nil : token)
    }

    /// `ntfy://<server>/<topic>`: opens the ntfy app on this topic.
    public var appLink: URL? { serverValidation.url.flatMap { NtfyServer.appLink(server: $0, topic: topic) } }

    /// The test button works whether or not push is enabled, as long as the server is valid.
    public func sendTest() async -> PushTestResult {
        guard let url = serverValidation.url else {
            if case .invalid(let r) = serverValidation { return .failed(r.message) }
            return .failed("Invalid server URL.")
        }
        let cfg = NtfyConfig(server: url.absoluteString, topic: topic, token: token.isEmpty ? nil : token)
        guard let request = NtfyTestRequest.build(config: cfg) else { return .failed("Invalid topic.") }
        do {
            let status = try await transport.send(request)
            return (200 ..< 300).contains(status) ? .sent : .failed("The server answered HTTP \(status).")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
