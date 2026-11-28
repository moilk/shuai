import ShuaiApp
import SwiftUI

struct TerminalWelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chrome) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    private var hasHosts: Bool { !model.hosts.hosts.isEmpty }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    ShuaiTerminalMark()
                        .frame(height: typeSize.isAccessibilitySize ? 124 : 168)
                        .frame(maxWidth: 350)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)

                    VStack(spacing: 9) {
                        Text(hasHosts ? "Choose a host" : "Connect to a server")
                            .font(.largeTitle.weight(.semibold))
                            .tracking(-0.8)
                            .foregroundStyle(.chromeText)
                            .accessibilityAddTraits(.isHeader)
                        Text(hasHosts
                            ? "Select a server in the sidebar or use Quick Switcher."
                            : "Save an SSH host to open your first terminal.")
                            .font(.body)
                            .foregroundStyle(.chromeSecondary)
                            .frame(maxWidth: 350)
                    }
                    .multilineTextAlignment(.center)

                    actions
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            ZStack {
                Color(palette.surface)
                RadialGradient(
                    colors: [Color(palette.accent).opacity(palette.prefersDark ? 0.11 : 0.14), .clear],
                    center: UnitPoint(x: 0.5, y: 0.43), startRadius: 0, endRadius: 420
                )
                Canvas { context, size in
                    let spacing: CGFloat = 22
                    let xOffset = (size.width / 2).truncatingRemainder(dividingBy: spacing)
                    let yOffset = (size.height / 2).truncatingRemainder(dividingBy: spacing)
                    var dots = Path()
                    for x in stride(from: xOffset, to: size.width, by: spacing) {
                        for y in stride(from: yOffset, to: size.height, by: spacing) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                        }
                    }
                    context.fill(dots, with: .color(Color(palette.secondaryText).opacity(0.32)))
                }
                .mask {
                    RadialGradient(colors: [.black, .clear], center: .center, startRadius: 45, endRadius: 420)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
        .toolbarBackground(.chromeSurface, for: .navigationBar)
    }

    private var actions: some View {
        VStack(spacing: 13) {
            if hasHosts {
                Button(action: model.openQuickSwitcher) {
                    HStack(spacing: 9) {
                        Label("Quick Switcher", systemImage: "magnifyingglass")
                        if !typeSize.isAccessibilitySize {
                            Text("⌘K")
                                .font(.subheadline.monospaced())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color(palette.surface).opacity(0.12), in: .rect(cornerRadius: 5))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(WelcomeActionStyle())
                .accessibilityIdentifier("welcome-quick-switcher")

                Button { model.request(.newHost) } label: {
                    Label("New Host", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.chromeText)
            } else {
                Button { model.request(.newHost) } label: {
                    Label("Add your first host", systemImage: "plus")
                }
                .buttonStyle(WelcomeActionStyle())
                .accessibilityIdentifier("add-first-host")
            }
        }
    }
}

private struct ShuaiTerminalMark: View {
    @Environment(\.chrome) private var palette

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.76, 234)
            let height = min(geometry.size.height * 0.74, 120)
            let markSize = min(height - 31, 68)
            let panel = RoundedRectangle(cornerRadius: 17)
            ZStack {
                panel
                    .fill(Color(palette.elevated).opacity(0.55))
                    .overlay { panel.strokeBorder(Color(palette.accent).opacity(0.20), lineWidth: 1) }
                    .frame(width: width, height: height)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -20, y: 5)

                panel
                    .fill(Color(palette.elevated))
                    .overlay { panel.strokeBorder(Color(palette.accent).opacity(0.24), lineWidth: 1) }
                    .frame(width: width, height: height)
                    .rotationEffect(.degrees(9))
                    .offset(x: 18, y: -8)

                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        ForEach(0..<3) { _ in
                            Circle().fill(Color(palette.secondaryText).opacity(0.50)).frame(width: 5, height: 5)
                        }
                        Spacer()
                        Image(systemName: "lock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.chromeSecondary)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 27)
                    Rectangle().fill(.chromeSeparator).frame(height: 1)
                    HStack(spacing: 0) {
                        Image("ShuaiMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: markSize, height: markSize)
                            .foregroundStyle(.chromeAccent)
                        Text("shuai")
                            .font(.system(size: 40, weight: .semibold))
                            .tracking(-1.7)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.chromeText)
                    }
                    .padding(.trailing, 15)
                    .frame(maxHeight: .infinity)
                }
                .frame(width: width, height: height)
                .background(Color(palette.elevated), in: panel)
                .overlay { panel.strokeBorder(Color(palette.accent).opacity(0.42), lineWidth: 1) }
                .shadow(color: .black.opacity(palette.prefersDark ? 0.34 : 0.14), radius: 20, x: 0, y: 13)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WelcomeActionStyle: ButtonStyle {
    @Environment(\.chrome) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.chromeSurface)
            .padding(.horizontal, 19)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(Color(palette.accent), in: .rect(cornerRadius: 13))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
