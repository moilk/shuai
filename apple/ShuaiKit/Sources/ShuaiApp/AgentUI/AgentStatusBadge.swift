import SwiftUI

/// Small colored dot/label for an agent's state (pane badge, sidebar row).
public struct AgentStatusBadge: View {
    public let badge: PaneBadge
    public var showsLabel: Bool

    public init(_ badge: PaneBadge, showsLabel: Bool = false) {
        self.badge = badge
        self.showsLabel = showsLabel
    }

    public static func color(for badge: PaneBadge) -> Color {
        switch badge {
        case .working: .blue
        case .needsPermission: .orange
        case .needsInput: .yellow
        case .done: .green
        case .failed: .red
        case .idle: .gray
        }
    }

    public static func label(for badge: PaneBadge) -> String {
        switch badge {
        case .working: "Working"
        case .needsPermission: "Needs permission"
        case .needsInput: "Needs input"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Self.color(for: badge)).frame(width: 8, height: 8)
            if showsLabel { Text(Self.label(for: badge)).font(.caption) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: badge))
    }
}

#if DEBUG
#Preview("Badges") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach([PaneBadge.working, .needsPermission, .needsInput, .done, .failed, .idle], id: \.self) {
            AgentStatusBadge($0, showsLabel: true)
        }
    }
    .padding()
}
#endif
