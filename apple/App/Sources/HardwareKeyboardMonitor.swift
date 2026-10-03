import GameController
import Observation

/// Tracks whether a hardware keyboard is attached (decides docked vs floating accessory bar).
@MainActor @Observable
final class HardwareKeyboardMonitor {
    private(set) var isConnected: Bool
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        isConnected = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
            })
        }
    }

    // Lives as long as the app (owned by AppModel): observers are never removed.
}
