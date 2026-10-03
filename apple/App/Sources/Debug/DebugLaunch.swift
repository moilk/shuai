#if DEBUG
import Foundation
import ShuaiApp

/// DEBUG-only launch arguments for scripted simulator runs (never compiled into Release):
///
/// - `-debugHostFile <path>`: JSON `{name, host, port, user, keyPath, [tmuxSession]}`. The key is
///   imported from that path on the Mac (the simulator can read host paths), a host profile is
///   created (or reused by name) and selected, which connects it.
/// - `-debugAutoAcceptHostKey`: answers the TOFU prompt with "trust" (scripted runs only).
/// - `-debugSendAfterConnect <text>`: types `text` + Enter shortly after the session attaches.
enum DebugLaunch {
    private static let args = ProcessInfo.processInfo.arguments

    static func value(of flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var autoAccept: Bool { args.contains("-debugAutoAcceptHostKey") }
    static var sendAfterConnect: String? { value(of: "-debugSendAfterConnect") }

    private struct HostFile: Decodable {
        var name: String
        var host: String
        var port: Int?
        var user: String
        var keyPath: String
        var tmuxSession: String?
    }

    @MainActor
    static func applyIfRequested(model: AppModel) async {
        guard let path = value(of: "-debugHostFile") else { return }
        do {
            let file = try JSONDecoder().decode(HostFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let keyData = try Data(contentsOf: URL(fileURLWithPath: file.keyPath))
            let keyName = "debug-\(file.name)"
            let key = try model.keys.items.first { $0.name == keyName }
                ?? model.keys.importKey(data: keyData, name: keyName, passphrase: nil)
            var profile = model.hosts.hosts.first { $0.name == file.name }
                ?? HostProfile(name: file.name, host: file.host, username: file.user)
            profile.host = file.host
            profile.port = file.port ?? 22
            profile.username = file.user
            profile.auth = .key(keyID: key.id)
            profile.tmux = TmuxPrefs(enabled: true, sessionName: file.tmuxSession ?? "shuai-sim-test")
            if model.hosts.host(id: profile.id) == nil { try model.hosts.add(profile) } else { try model.hosts.update(profile) }
            model.selection = profile.id
            NSLog("[debug] host \(profile.name) ready, selected")
        } catch {
            NSLog("[debug] -debugHostFile failed: \(error)")
        }
    }

    @MainActor
    static func autoAnswer(controller: SessionController) async {
        guard autoAccept, case .hostKey(let challenge)? = controller.pendingPrompt else { return }
        NSLog("[debug] auto-accepting host key \(challenge.fingerprint)")
        controller.answerHostKey(accept: true)
    }

    @MainActor
    static func sendAfterConnect(controller: SessionController) async {
        guard controller.state == .connected, let text = sendAfterConnect else { return }
        // Give tmux a moment to draw before typing.
        try? await Task.sleep(for: .seconds(2.5))
        guard controller.state == .connected, !sentOnce else { return }
        sentOnce = true
        NSLog("[debug] sending after connect: \(text)")
        controller.sendInput(text + "\r")
    }

    @MainActor private static var sentOnce = false
}
#endif
