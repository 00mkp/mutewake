import Foundation
import UserNotifications

// Banners, posted as mutewake through the notification center. Falls back to
// osascript (which macOS attributes to Script Editor) only when the center can't
// be used at all - not when you have turned mutewake's notifications off.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    // Set when asking for permission fails outright (not when you say no).
    // macOS then records mutewake as "off", which would otherwise read as your
    // choice and silence every banner - so use the osascript path instead.
    private var unavailable = false

    /// Call at launch. Asks for permission up front, so the prompt appears right
    /// after install rather than in the middle of a wake.
    func activate() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    self.unavailable = true
                    log("notifications unavailable (\(error.localizedDescription)); using osascript")
                } else {
                    log(granted ? "notifications: allowed" : "notifications: declined")
                }
            }
        }
    }

    func post(_ body: String) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = "mutewake"
            content.body = body
            // No sound: the whole point is that the Mac just went quiet.
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil)) { error in
                if let error {
                    log("banner via Script Editor (\(error.localizedDescription))")
                    DispatchQueue.main.async { postViaScript(body) }
                }
            }
        }
        if unavailable {
            postViaScript(body)
            return
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                send()
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if granted { send() }
                    else if error != nil {
                        self.unavailable = true
                        DispatchQueue.main.async { postViaScript(body) }
                    }
                }
            case .denied:
                // Your choice in System Settings; don't route around it.
                log("banner skipped (notifications are off for mutewake)")
            @unknown default:
                DispatchQueue.main.async { postViaScript(body) }
            }
        }
    }

    // mutewake is an accessory app, so it is never "frontmost" - but without this
    // the center would treat it as foreground and suppress the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// The pre-0.4.1 path: works without any permission, but the banner shows
/// Script Editor's name and icon.
func postViaScript(_ body: String) {
    let escaped = body.replacingOccurrences(of: "\"", with: "")
    osascript("display notification \"\(escaped)\" with title \"mutewake\"")
}

func notify(_ body: String) {
    Notifier.shared.post(body)
}
