import AMDBCore
import Foundation

public struct CachedRatings: Codable, Sendable, Equatable {
    public let ratings: Ratings
    public let fetchedAt: Date
}

/// On-device ratings cache so MDBList's daily quota is spent once per title per week.
/// The file name carries a version: bump it when `Ratings` gains a source so old entries are refetched.
public actor RatingsCache {
    private let fileURL: URL?
    private let ttl: TimeInterval
    private var entries: [String: CachedRatings]

    public init(fileURL: URL?, ttl: TimeInterval = 7 * 24 * 3600) {
        self.fileURL = fileURL
        self.ttl = ttl
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: CachedRatings].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AMDB/ratings-v2.json")
    }

    public func fresh(_ imdbID: String, now: Date = Date()) -> Ratings? {
        guard let entry = entries[imdbID], now.timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry.ratings
    }

    public func store(_ ratings: Ratings, for imdbID: String, now: Date = Date()) {
        entries[imdbID] = CachedRatings(ratings: ratings, fetchedAt: now)
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
