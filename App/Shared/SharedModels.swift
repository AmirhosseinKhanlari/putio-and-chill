import ActivityKit
import Foundation

/// App Group shared by the app and the widget extension.
enum AppGroup {
    static let id = "group.app.amdb"
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// One Continue Watching tile for the widget; posters are saved as files in the App Group.
struct WidgetItem: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let imageFile: String?
    let link: URL
}

struct WidgetSnapshot: Codable {
    var continueWatching: [WidgetItem]
    var updatedAt: Date

    static let fileName = "widget-snapshot.json"

    static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.container?.appending(path: fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = AppGroup.container?.appending(path: Self.fileName), let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func imageURL(_ file: String) -> URL? { AppGroup.container?.appending(path: file) }
}

/// Live Activity for a put.io transfer (Lock Screen + Dynamic Island).
struct TransferActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var percent: Int
        var status: String
        var detail: String
        var isReady: Bool
        var link: URL?
    }

    let title: String
    let transferID: Int64
}
