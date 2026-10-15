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
    static let defaultsKey = "topshelf.feed"

    /// tvOS only lets apps write files under Library/Caches, in a shared container too: a file at the container's root
    /// is silently never written (the Top Shelf then stays empty). The feed lives in the group's shared defaults, with
    /// a copy in the container's Caches.
    static var fileURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let caches = container.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches.appending(path: "topshelf.json")
    }

    static func load() -> TopShelfFeed? {
        let data = UserDefaults(suiteName: appGroup)?.data(forKey: defaultsKey)
            ?? fileURL.flatMap { try? Data(contentsOf: $0) }
        return data.flatMap { try? JSONDecoder().decode(TopShelfFeed.self, from: $0) }
    }

    /// Saves the feed; returns true when it changed (so the Top Shelf should reload).
    @discardableResult
    func save() -> Bool {
        guard Self.load() != self, let data = try? JSONEncoder().encode(self) else { return false }
        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.defaultsKey)
        if let url = Self.fileURL { try? data.write(to: url, options: .atomic) }
        return true
    }
}
