import Foundation

/// What the Apple TV Top Shelf shows, written by the TV app into the App Group and read by the Top Shelf extension.
struct TopShelfFeed: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let title: String
        /// Wide artwork (TMDB backdrop URL).
        let imageURL: URL?
        /// amdb:// link opened when the item is selected (play = resume, display = open the title).
        let playLink: URL?
        let displayLink: URL
    }

    struct Section: Codable, Equatable {
        let title: String
        let items: [Item]
    }

    var sections: [Section]

    static let appGroup = "group.app.amdb"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "topshelf.json")
    }

    static func load() -> TopShelfFeed? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TopShelfFeed.self, from: data)
    }

    /// Saves the feed; returns true when it changed (so the Top Shelf should reload).
    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, Self.load() != self, let data = try? JSONEncoder().encode(self) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }
}
