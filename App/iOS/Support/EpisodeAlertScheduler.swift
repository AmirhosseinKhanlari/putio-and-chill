import AMDBCore
import AMDBKit
import UserNotifications

/// Schedules a local notification on each followed show's next release day (re-planned when the app opens, in the
/// background refresh, and whenever a show is followed or Settings change).
@MainActor
enum EpisodeAlertScheduler {
    static func reschedule(_ app: AppModel) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("episode-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard app.settings.episodeAlerts, !app.episodeAlerts.followed.isEmpty else { return }
        let episodes = await app.episodeAlerts.upcoming()
        for alert in EpisodeAlerts.alerts(for: episodes, hour: app.settings.episodeAlertHour, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.userInfo = ["link": DeepLink.title(tmdbID: alert.tmdbID, kind: .tv).url.absoluteString]
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alert.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
    }

    /// Asks for permission the first time a show is followed.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// Tapping a notification opens what it's about (a show's page); notifications also show while the app is open.
final class NotificationLinks: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationLinks()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["link"] as? String else { return }
        PendingLink.set(link)
        await MainActor.run { NotificationCenter.default.post(name: PendingLink.notification, object: nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
