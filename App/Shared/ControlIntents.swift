import AppIntents
import Foundation

/// A screen to open, handed from a control (Control Center, Lock Screen, Action button) to the app. Kept in the App
/// Group so it survives a cold launch; the notification covers an app that's already running.
enum PendingLink {
    static let notification = Notification.Name("app.amdb.pendingLink")
    private static let key = "pendingLink"

    static func set(_ url: String) {
        UserDefaults(suiteName: AppGroup.id)?.set(url, forKey: key)
    }

    /// The waiting link, once.
    static func take() -> URL? {
        guard let defaults = UserDefaults(suiteName: AppGroup.id), let value = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return URL(string: value)
    }
}

/// Opens Putio & Chill on Surprise Me.
struct OpenSurpriseIntent: AppIntent {
    static let title: LocalizedStringResource = "Surprise Me"
    static let description = IntentDescription("Opens Putio & Chill's Surprise Me: pick a mood, get a great movie or series.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingLink.set("amdb://surprise")
        await MainActor.run { NotificationCenter.default.post(name: PendingLink.notification, object: nil) }
        return .result()
    }
}
