import ShuaiApp
import SwiftUI

/// Full screen's only chrome: a status symbol that opens a menu. A menu overlay (or a button in the
/// window tab strip), so it never resizes the terminal. Prominent when the connection is not healthy
/// or a permission is pending.
struct FullScreenHandle: View {
    @Environment(AppModel.self) private var model
    let presentation: ConnectionPresentation
    let prominent: Bool
    let connected: Bool
    let disconnect: () -> Void
    let reconnect: () -> Void

    var body: some View {
        Menu {
            Section { Text(verbatim: presentation.accessibilityLabel) }
            if connected {
                Button("Disconnect", systemImage: "bolt.slash", role: .destructive, action: disconnect)
            } else {
                Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
            }
            Button("Show Sidebar", systemImage: "sidebar.left") { model.columnVisibility = .all }
                .accessibilityIdentifier("full-screen-show-sidebar")
            Button("Quick Switcher", systemImage: "magnifyingglass") { model.openQuickSwitcher() }
                .accessibilityIdentifier("full-screen-quick-switcher")
            Button("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") { model.setFullScreen(false) }
                .accessibilityIdentifier("full-screen-exit")
        } label: {
            Image(systemName: presentation.symbol)
                .foregroundStyle(prominent ? AnyShapeStyle(presentation.tone.tint) : AnyShapeStyle(.chromeSecondary))
                .frame(width: 44, height: 44)
                .background(prominent ? AnyShapeStyle(.chromeElevated) : AnyShapeStyle(.clear), in: Circle())
                .opacity(prominent ? 1 : 0.6)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Full screen menu")
        .accessibilityValue(presentation.accessibilityLabel)
        .accessibilityIdentifier("full-screen-handle")
    }
}
