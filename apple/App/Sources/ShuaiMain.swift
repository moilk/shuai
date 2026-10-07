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
                Button("New Host") { model.request(.newHost) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.canRequest(.newHost))
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.request(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(!model.canRequest(.settings))
                Button("Keys…") { model.request(.keys) }
                    .disabled(!model.canRequest(.keys))
            }
            CommandGroup(after: .toolbar) {
                // No chord: ⌃⌘F is delivered by the terminal's key command, and a second delivery
                // path would toggle straight back.
                Button(model.settings.fullScreen ? "Exit Full Screen" : "Enter Full Screen") { model.toggleFullScreen() }
                    .disabled(!model.settings.fullScreen && model.selection.flatMap { model.hosts.host(id: $0) } == nil)
            }
            CommandMenu("Go") {
                // Also works while the sidebar has focus; in the terminal the key command takes the chord.
                Button("Quick Switcher") { model.openQuickSwitcher() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.canRequest(.quickSwitcher))
                Button("Next Agent Needing Attention") { model.jumpNextAttention() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("tmux") {
                // Mirrors `ShortcutMap.defaults` for discoverability and pointer use. The items carry no
                // `.keyboardShortcut`: the terminal's priority key commands already own these chords and
                // tmux commands are not idempotent (a second delivery would open two windows). A menu
                // chord would add a second path whose double delivery can only be confirmed on a device
                // (device checklist). Without a live or polling tmux the items are disabled.
                ForEach(TmuxMenuState.items(shortcuts: model.shortcuts, availability: model.tmuxMenuAvailability)) { item in
                    Button(item.title) { model.performTmuxMenuItem(id: item.id) }
                        .disabled(!item.enabled)
                }
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
