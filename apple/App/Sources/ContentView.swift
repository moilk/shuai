import SwiftUI
import ShuaiCore

struct ContentView: View {
    #if DEBUG
    // `-debugTerminal` (launch argument) opens the terminal playground directly.
    @State private var showTerminalDebug = ProcessInfo.processInfo.arguments.contains("-debugTerminal")
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("shuai").font(.largeTitle.bold())
                Text("core \(ShuaiCore.coreVersion())").foregroundStyle(.secondary)
                #if DEBUG
                Button("Debug: Terminal") { showTerminalDebug = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("debug-terminal")
                #endif
            }
            #if DEBUG
            .navigationDestination(isPresented: $showTerminalDebug) { TerminalDebugScreen() }
            #endif
        }
    }
}
