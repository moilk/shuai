import Foundation
import ShuaiApp
import UserNotifications

/// Local notifications for "an agent wants you" while the app is not active. Best effort: iOS
/// suspends the app shortly after it leaves the foreground, so only transitions that arrive
/// before that are posted. Authorization is requested lazily, after the user was told why.
@MainActor
final class LocalNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// (profile id, pane id) of a tapped notification.
    var onOpen: ((UUID, String?) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ content: LocalNotificationContent, profileID: UUID) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let c = UNMutableNotificationContent()
        c.title = content.title
        c.body = content.body
        c.sound = .default
        c.threadIdentifier = "shuai-\(content.key.host)"
        c.userInfo = ["profile": profileID.uuidString, "pane": content.paneID ?? ""]
        try? await center.add(UNNotificationRequest(identifier: content.identifier, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [] }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let s = info["profile"] as? String, let id = UUID(uuidString: s) else { return }
        let pane = (info["pane"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run { onOpen?(id, pane) }
    }
}
