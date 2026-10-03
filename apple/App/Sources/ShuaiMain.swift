import ShuaiApp
import SwiftUI

@main
struct ShuaiMain: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let args = ProcessInfo.processInfo.arguments
        _model = State(initialValue: AppModel(ephemeral: args.contains("-uiTesting")))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Host") { model.editor = .new }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Disconnect") { disconnectSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reconnect") { reconnectSelected() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func selectedController() -> SessionController? {
        guard let id = model.selection, let host = model.hosts.host(id: id) else { return nil }
        return model.sessions.controller(for: host)
    }

    private func disconnectSelected() {
        guard let controller = selectedController() else { return }
        Task { await controller.disconnect() }
    }

    private func reconnectSelected() {
        guard let controller = selectedController() else { return }
        Task { await controller.reconnect() }
    }
}
