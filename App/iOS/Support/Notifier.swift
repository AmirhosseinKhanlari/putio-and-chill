import AMDBKit
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func ready(_ transfer: TrackedTransfer) {
        let content = UNMutableNotificationContent()
        content.title = "\(transfer.pending.title) is ready"
        content.body = "It's in your put.io. Tap to watch."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ready-\(transfer.id)", content: content, trigger: nil))
    }
}
