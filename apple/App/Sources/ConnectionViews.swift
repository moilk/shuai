import ShuaiApp
import SwiftUI

/// Views for `ConnectionPresentation`; all text and structure come from the presentation.

extension SessionState.Status {
    /// Colour reinforces the symbol shape; it never carries the state alone.
    var tint: Color {
        switch self {
        case .off: .gray
        case .busy: .yellow
        case .connected: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct ConnectionActionButtons: View {
    let actions: [ConnectionPresentation.Action]
    let perform: (ConnectionPresentation.Action) -> Void

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
            // The 44 pt minimum lives in the label, so the whole height is tappable.
            let button = Button { perform(action) } label: {
                Text(action.title)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(action.accessibilityIdentifier)
            if index == 0 {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }
}

/// Blocking states (connecting, signing in, host key, failed): a centred card. The scrim appears
/// only when the presentation dims the terminal.
struct ConnectionCard: View {
    let presentation: ConnectionPresentation
    let perform: (ConnectionPresentation.Action) -> Void

    var body: some View {
        ZStack {
            if presentation.dimsTerminal {
                Color.black.opacity(0.3).ignoresSafeArea()
            }
            VStack(spacing: 12) {
                if presentation.showsProgress {
                    ProgressView()
                } else {
                    Image(systemName: presentation.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(presentation.tone.tint)
                        .accessibilityHidden(true)
                }
                Text(verbatim: presentation.title).font(.headline).multilineTextAlignment(.center)
                if let detail = presentation.detail(at: .now) {
                    Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !presentation.actions.isEmpty {
                    HStack {
                        ConnectionActionButtons(actions: presentation.actions, perform: perform)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }
}

/// Non-blocking states (reconnecting, disconnected): a compact bar with no scrim, so the last
/// output stays readable and scrollable.
struct ConnectionStrip: View {
    let presentation: ConnectionPresentation
    let perform: (ConnectionPresentation.Action) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if presentation.showsProgress {
                ProgressView()
            } else {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.tone.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: presentation.title).font(.subheadline.weight(.semibold))
                detail
            }
            Spacer(minLength: 8)
            ConnectionActionButtons(actions: presentation.actions, perform: perform)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }

    @ViewBuilder private var detail: some View {
        if presentation.retryAt != nil {
            // Ticks only while a retry is scheduled.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                detailText(presentation.detail(at: context.date))
            }
        } else {
            detailText(presentation.detail(at: .now))
        }
    }

    @ViewBuilder private func detailText(_ text: String?) -> some View {
        if let text {
            Text(verbatim: text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Toolbar status: a shape per status plus a spoken "<host>: <state>".
struct StatusIndicator: View {
    let presentation: ConnectionPresentation

    var body: some View {
        Image(systemName: presentation.symbol)
            .foregroundStyle(presentation.tone.tint)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("connection-status")
    }
}
