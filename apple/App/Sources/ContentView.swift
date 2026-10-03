import SwiftUI
import ShuaiCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("shuai").font(.largeTitle.bold())
            Text("core \(ShuaiCore.coreVersion())").foregroundStyle(.secondary)
        }
    }
}
