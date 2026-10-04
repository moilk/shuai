import ShuaiApp
import SwiftUI

@main
struct ShuaiMain: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // UI tests: temp files and in-memory secrets. Not available in Release builds.
        let ephemeral = ProcessInfo.processInfo.arguments.contains("-uiTesting")
        #else
        let ephemeral = false
        #endif
        _model = State(initialValue: AppModel(ephemeral: ephemeral))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
                // ntfy push taps: shuai://open?host=<uuid>&pane=%N
                .onOpenURL { url in Task { await model.open(url: url) } }
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
            CommandMenu("Go") {
                // Also works while the sidebar has focus; in the terminal the key command takes the chord.
                Button("Quick Switcher") { model.openQuickSwitcher() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Next Agent Needing Attention") { model.jumpNextAttention() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
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
