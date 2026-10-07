import GameController
import Observation
import ShuaiTerminal
import UIKit

/// Tracks whether a hardware keyboard is attached and whether the *software* keyboard is on screen;
/// together they decide docked vs floating accessory bar (`AccessoryBarPlacement`).
///
/// Hardware presence comes only from GameController connect/disconnect notifications. Software keyboard
/// visibility comes from keyboard frame notifications but only counts a *tall* frame, so the short frame
/// produced by our own docked bar (after `reloadInputViews`) can never flip the decision. Every setter is
/// idempotent so a notification that changes nothing triggers no SwiftUI update.
@MainActor @Observable
final class HardwareKeyboardMonitor {
    private(set) var isConnected: Bool
    private(set) var softwareKeyboardVisible = false
    #if DEBUG
    /// `-debugHardwareKeyboard`: a hardware keyboard and never a software one (the simulator has no real keyboards).
    private let forced = ProcessInfo.processInfo.arguments.contains("-debugHardwareKeyboard")
    #endif
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        isConnected = GCKeyboard.coalesced != nil
        #if DEBUG
        if forced { isConnected = true }
        #endif
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setConnected(GCKeyboard.coalesced != nil) }
            })
        }
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            MainActor.assumeIsolated { self?.setSoftwareKeyboard(AccessoryBarPlacement.isSoftwareKeyboard(frameHeight: end.height)) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSoftwareKeyboard(false) }
        })
    }

    private func setConnected(_ value: Bool) {
        #if DEBUG
        if forced { return }
        #endif
        if isConnected != value { isConnected = value }
    }

    private func setSoftwareKeyboard(_ value: Bool) {
        #if DEBUG
        if forced { return }
        #endif
        if softwareKeyboardVisible != value { softwareKeyboardVisible = value }
    }

    func placement(preferFloating: Bool) -> AccessoryBarPlacement {
        AccessoryBarPlacement.decide(
            hardwareKeyboard: isConnected, preferFloating: preferFloating, softwareKeyboardVisible: softwareKeyboardVisible)
    }

    // Lives as long as the app (owned by AppModel): observers are never removed.
}
