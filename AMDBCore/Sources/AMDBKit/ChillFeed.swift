import AMDBCore
import Foundation
import Observation

/// A chill title matched to TMDB, saved so the rows show instantly next time.
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

public struct ChillFeedSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var movies: [FeedTitle]
    public var shows: [FeedTitle]
    /// chill's own lists from the last time they could be read, reused when they can't be this time.
    public var chillMovies: [ChillTitle]?
    public var chillShows: [ChillTitle]?
    /// Titles already matched to TMDB, so opening the app doesn't look them all up again.
    public var resolved: [String: FeedTitle]?
    /// The last time the chill settings-switch fallback was allowed (at most every six hours).
    public var lastSettingsSwitch: Date?
}

/// "Latest" rows for the Movies and TV Shows tabs: every chill list (with a chill account) plus MyMoviz's newest
/// movies and shows, combined, matched to TMDB and kept for six hours (chill's movie lists briefly switch the
/// source saved in the chill account, so this shouldn't run often).
@Observable @MainActor
public final class ChillFeed {
    public private(set) var movies: [CatalogItem] = []
    public private(set) var shows: [CatalogItem] = []
    public private(set) var isLoading = false
    public private(set) var updatedAt: Date?

    public static let maxAge: TimeInterval = 6 * 3600
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var readDisk = false
    @ObservationIgnored private var chillMovies: [ChillTitle]?
    @ObservationIgnored private var chillShows: [ChillTitle]?
    @ObservationIgnored private var resolved: [String: CatalogItem] = [:]
    @ObservationIgnored private var lastSettingsSwitch: Date?

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static func defaultURL() -> URL {
        StorageLocation.directory.appending(path: "chill-feed.json")
    }

    public func load(service: (any ChillCatalogService)?, extra: [any LatestTitlesSource] = [],
                     catalog: (any CatalogService)?, force: Bool = false, now: Date = Date(), limit: Int = 48) async {
        readCacheOnce()
        if !force, let updatedAt, now.timeIntervalSince(updatedAt) < Self.maxAge { return }
        guard service != nil || !extra.isEmpty, let catalog, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // The settings-switch fallback changes the chill account's saved source, so it may run at most every six hours.
        let allowSwitch = lastSettingsSwitch.map { now.timeIntervalSince($0) >= Self.maxAge } ?? true
        if allowSwitch, service != nil { lastSettingsSwitch = now }
        async let freshChillMovies = try? service?.combinedMovies(allowSettingsSwitch: allowSwitch)
        async let freshChillShows = try? service?.combinedShows()
        var movieLists: [[ChillTitle]] = []
        var showLists: [[ChillTitle]] = []
        for source in extra {
            guard let list = try? await source.latestTitles() else { continue }
            if source.kind == .tv { showLists.append(list) } else { movieLists.append(list) }
        }
        let (fetchedMovies, fetchedShows) = await (freshChillMovies, freshChillShows)
        // chill couldn't be read this time: keep its last lists so the row doesn't lose them.
        if service != nil {
            if let fetchedMovies { chillMovies = fetchedMovies }
            if let fetchedShows { chillShows = fetchedShows }
        }
        if service != nil, let chillMovies { movieLists.insert(chillMovies, at: 0) }
        if service != nil, let chillShows { showLists.insert(chillShows, at: 0) }
        let foundMovies: [ChillTitle]? = movieLists.isEmpty ? nil : ChillMerge.combine(movieLists)
        let foundShows: [ChillTitle]? = showLists.isEmpty ? nil : ChillMerge.combine(showLists)
        guard foundMovies != nil || foundShows != nil else { return }
        let resolvedMovies = await resolveRemembering(Array((foundMovies ?? []).prefix(limit)), catalog: catalog)
        let resolvedShows = await resolveRemembering(Array((foundShows ?? []).prefix(limit)), catalog: catalog)
        if foundMovies != nil { movies = resolvedMovies }
        if foundShows != nil { shows = resolvedShows }
        updatedAt = now
        save()
    }

    public func clear() {
        movies = []
        shows = []
        updatedAt = nil
        chillMovies = nil
        chillShows = nil
        resolved = [:]
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Like `resolve`, but titles matched before aren't looked up again.
    private func resolveRemembering(_ titles: [ChillTitle], catalog: any CatalogService) async -> [CatalogItem] {
        let unknown = titles.filter { resolved[$0.mergeKey] == nil }
        for (key, item) in await Self.resolveKeys(unknown, catalog: catalog) { resolved[key] = item }
        var seen: Set<String> = []
        return titles.compactMap { resolved[$0.mergeKey] }.filter { seen.insert($0.id).inserted }
    }

    /// TMDB item for each title (by IMDb id, else by title and year), in the same order; unmatched titles are dropped.
    static func resolve(_ titles: [ChillTitle], catalog: any CatalogService) async -> [CatalogItem] {
        let found = await resolveKeys(titles, catalog: catalog)
        var seen: Set<String> = []
        return titles.compactMap { found[$0.mergeKey] }.filter { seen.insert($0.id).inserted }
    }

    /// Matches keyed by each title's merge key; six lookups at a time.
    static func resolveKeys(_ titles: [ChillTitle], catalog: any CatalogService) async -> [String: CatalogItem] {
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

    private static func resolve(_ title: ChillTitle, catalog: any CatalogService) async -> CatalogItem? {
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
              let snapshot = try? JSONDecoder().decode(ChillFeedSnapshot.self, from: data) else { return }
        movies = snapshot.movies.map(\.item)
        shows = snapshot.shows.map(\.item)
        updatedAt = snapshot.updatedAt
        chillMovies = snapshot.chillMovies
        chillShows = snapshot.chillShows
        resolved = (snapshot.resolved ?? [:]).mapValues(\.item)
        lastSettingsSwitch = snapshot.lastSettingsSwitch
    }

    private func save() {
        guard let fileURL, let updatedAt else { return }
        // Remembered matches stay bounded to titles the lists still contain.
        if resolved.count > 600 {
            let keys = Set(((chillMovies ?? []) + (chillShows ?? [])).map(\.mergeKey))
            resolved = resolved.filter { keys.contains($0.key) }
        }
        let snapshot = ChillFeedSnapshot(updatedAt: updatedAt, movies: movies.map(FeedTitle.init), shows: shows.map(FeedTitle.init),
                                         chillMovies: chillMovies, chillShows: chillShows,
                                         resolved: resolved.mapValues(FeedTitle.init), lastSettingsSwitch: lastSettingsSwitch)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
