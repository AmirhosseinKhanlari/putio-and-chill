import AMDBCore
import Foundation

public struct CachedRatings: Codable, Sendable, Equatable {
    public let ratings: Ratings
    public let fetchedAt: Date
}

/// On-device ratings cache so MDBList's daily quota is spent once per title per week.
/// Empty answers are kept only briefly: a title that has no scores yet (or a lookup that missed) gets another try soon
/// instead of showing nothing for a week.
/// The file name carries a version: bump it when `Ratings` gains a source or the keys change so old entries are dropped.
public actor RatingsCache {
    private let fileURL: URL?
    private let ttl: TimeInterval
    private let emptyTTL: TimeInterval
    private var entries: [String: CachedRatings]

    public init(fileURL: URL?, ttl: TimeInterval = 7 * 24 * 3600, emptyTTL: TimeInterval = 3600) {
        self.fileURL = fileURL
        self.ttl = ttl
        self.emptyTTL = emptyTTL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: CachedRatings].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public static func defaultURL() -> URL {
        StorageLocation.directory.appending(path: "ratings-v3.json")
    }

    /// "mdblist:imdb:show:tt0903747", "trakt:tmdb:movie:550": who answered, which id was asked, and for what kind.
    public static func key(source: String, imdbID: String?, tmdbID: Int?, kind: MediaKind) -> String {
        let type = kind == .tv ? "show" : "movie"
        if let imdbID, !imdbID.isEmpty { return "\(source):imdb:\(type):\(imdbID)" }
        return "\(source):tmdb:\(type):\(tmdbID.map(String.init) ?? "")"
    }

    public func fresh(_ key: String, now: Date = Date()) -> Ratings? {
        guard let entry = entries[key] else { return nil }
        let age = now.timeIntervalSince(entry.fetchedAt)
        return age < (entry.ratings.isEmpty ? emptyTTL : ttl) ? entry.ratings : nil
    }

    public func store(_ ratings: Ratings, for key: String, now: Date = Date()) {
        entries[key] = CachedRatings(ratings: ratings, fetchedAt: now)
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
