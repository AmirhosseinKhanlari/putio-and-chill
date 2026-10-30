import AMDBCore
import Foundation
import Observation

/// A latest-list title matched to TMDB, saved so the rows show instantly next time.
public struct FeedTitle: Codable, Sendable, Hashable {
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public let overview: String
    public let posterPath: String?
    public let backdropPath: String?
    public let year: Int?
    public let voteAverage: Double?

    init(_ item: CatalogItem) {
        tmdbID = item.tmdbID; kind = item.mediaType; title = item.title; overview = item.overview
        posterPath = item.posterPath; backdropPath = item.backdropPath; year = item.year; voteAverage = item.voteAverage
    }

    public var item: CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: kind, title: title, overview: overview, posterPath: posterPath,
                    backdropPath: backdropPath, year: year, voteAverage: voteAverage)
    }
}

public struct LatestFeedSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var movies: [FeedTitle]
    public var shows: [FeedTitle]
    /// Titles already matched to TMDB, so opening the app doesn't look them all up again.
    public var resolved: [String: FeedTitle]?
}

/// "Latest Movies / Latest Shows" rows for the Movies and TV Shows tabs: MyMoviz's newest movies and shows, matched
/// to TMDB and kept for six hours (and on disk, so the rows show at once next launch).
@Observable @MainActor
public final class LatestFeed {
    public private(set) var movies: [CatalogItem] = []
    public private(set) var shows: [CatalogItem] = []
    public private(set) var isLoading = false
    public private(set) var updatedAt: Date?

    public static let maxAge: TimeInterval = 6 * 3600
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var readDisk = false
    @ObservationIgnored private var resolved: [String: CatalogItem] = [:]

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static func defaultURL() -> URL {
        StorageLocation.directory.appending(path: "latest-feed.json")
    }

    public func load(sources: [any LatestTitlesSource], catalog: (any CatalogService)?, force: Bool = false,
                     now: Date = Date(), limit: Int = 48) async {
        readCacheOnce()
        if !force, let updatedAt, now.timeIntervalSince(updatedAt) < Self.maxAge { return }
        guard !sources.isEmpty, let catalog, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var movieLists: [[LatestTitle]] = []
        var showLists: [[LatestTitle]] = []
        for source in sources {
            guard let list = try? await source.latestTitles() else { continue }
            if source.kind == .tv { showLists.append(list) } else { movieLists.append(list) }
        }
        // A list that couldn't be read this time keeps the row it showed before.
        guard !movieLists.isEmpty || !showLists.isEmpty else { return }
        let foundMovies = Array(LatestTitle.combine(movieLists).prefix(limit))
        let foundShows = Array(LatestTitle.combine(showLists).prefix(limit))
        let resolvedMovies = await resolveRemembering(foundMovies, catalog: catalog)
        let resolvedShows = await resolveRemembering(foundShows, catalog: catalog)
        if !movieLists.isEmpty { movies = resolvedMovies }
        if !showLists.isEmpty { shows = resolvedShows }
        // Remembered matches stay bounded to titles the lists still contain.
        let keys = Set((foundMovies + foundShows).map(\.mergeKey))
        if resolved.count > 600 { resolved = resolved.filter { keys.contains($0.key) } }
        updatedAt = now
        save()
    }

    public func clear() {
        movies = []
        shows = []
        updatedAt = nil
        resolved = [:]
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Like `resolveKeys`, but titles matched before aren't looked up again.
    private func resolveRemembering(_ titles: [LatestTitle], catalog: any CatalogService) async -> [CatalogItem] {
        let unknown = titles.filter { resolved[$0.mergeKey] == nil }
        for (key, item) in await Self.resolveKeys(unknown, catalog: catalog) { resolved[key] = item }
        var seen: Set<String> = []
        return titles.compactMap { resolved[$0.mergeKey] }.filter { seen.insert($0.id).inserted }
    }

    /// Matches keyed by each title's merge key; six lookups at a time.
    static func resolveKeys(_ titles: [LatestTitle], catalog: any CatalogService) async -> [String: CatalogItem] {
        await withTaskGroup(of: (String, CatalogItem?).self) { group in
            var results: [String: CatalogItem] = [:]
            var next = 0
            func add(_ index: Int) {
                let title = titles[index]
                group.addTask { (title.mergeKey, await resolve(title, catalog: catalog)) }
            }
            while next < min(6, titles.count) { add(next); next += 1 }
            while let (key, item) = await group.next() {
                if let item { results[key] = item }
                if next < titles.count { add(next); next += 1 }
            }
            return results
        }
    }

    /// TMDB item for a title: by IMDb id, else by title and year.
    private static func resolve(_ title: LatestTitle, catalog: any CatalogService) async -> CatalogItem? {
        if let imdbID = title.imdbID, let item = try? await catalog.findByIMDb(imdbID), item.mediaType == title.kind {
            return item
        }
        let results = title.kind == .tv
            ? try? await catalog.searchTV(title: title.title, year: title.year)
            : try? await catalog.searchMovie(title: title.title, year: title.year)
        return results?.first
    }

    private func readCacheOnce() {
        guard !readDisk else { return }
        readDisk = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(LatestFeedSnapshot.self, from: data) else { return }
        movies = snapshot.movies.map(\.item)
        shows = snapshot.shows.map(\.item)
        updatedAt = snapshot.updatedAt
        resolved = (snapshot.resolved ?? [:]).mapValues(\.item)
    }

    private func save() {
        guard let fileURL, let updatedAt else { return }
        let snapshot = LatestFeedSnapshot(updatedAt: updatedAt, movies: movies.map(FeedTitle.init), shows: shows.map(FeedTitle.init),
                                          resolved: resolved.mapValues(FeedTitle.init))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
