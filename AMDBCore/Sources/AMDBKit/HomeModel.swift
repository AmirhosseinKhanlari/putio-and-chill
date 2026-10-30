import AMDBCore
import Foundation
import Observation

public struct CatalogRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let items: [CatalogItem]
    public init(id: String, title: String, items: [CatalogItem]) { self.id = id; self.title = title; self.items = items }
}

public struct Genre: Sendable, Hashable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

@Observable @MainActor
public final class HomeModel {
    public private(set) var hero: [CatalogItem] = []
    public private(set) var rows: [CatalogRow] = []
    public private(set) var isLoading = false
    public private(set) var error: AppError?

    private let catalog: any CatalogService
    private let store: LocalStore

    public init(catalog: any CatalogService, store: LocalStore) {
        self.catalog = catalog
        self.store = store
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let catalog = catalog
        async let trending = try? catalog.trending(nil)
        async let movies = try? catalog.popular(.movie)
        async let shows = try? catalog.popular(.tv)
        let lastPlayed = await store.snapshot.lastPlayed
        var recommendations: [CatalogItem]?
        if let lastPlayed {
            recommendations = try? await catalog.detail(lastPlayed.kind, id: lastPlayed.tmdbID).recommendations
        }
        let (trendingItems, movieItems, showItems) = await (trending, movies, shows)

        let visibleTrending = (trendingItems ?? []).filter { $0.mediaType != .person }
        hero = Array(visibleTrending.filter { $0.backdropPath != nil }.prefix(6))
        var built: [CatalogRow] = []
        if !visibleTrending.isEmpty { built.append(CatalogRow(id: "trending", title: "Trending Now", items: visibleTrending)) }
        if let lastPlayed, let recommendations, !recommendations.isEmpty {
            built.append(CatalogRow(id: "because", title: "Because you watched \(lastPlayed.title)", items: recommendations))
        }
        if let movieItems, !movieItems.isEmpty { built.append(CatalogRow(id: "movies", title: "Popular Movies", items: movieItems)) }
        if let showItems, !showItems.isEmpty { built.append(CatalogRow(id: "tv", title: "Popular TV", items: showItems)) }
        rows = built
        error = (trendingItems == nil && movieItems == nil && showItems == nil) ? .transport("Couldn't reach TMDB") : nil
    }
}

@Observable @MainActor
public final class BrowseModel {
    public let kind: MediaKind
    public private(set) var rows: [CatalogRow] = []
    /// New to Stream (movies) or New Episodes This Week (shows), shown above the other rows.
    public private(set) var newReleases: CatalogRow?
    public private(set) var isLoading = false
    private let catalog: any CatalogService
    private let now: @Sendable () -> Date
    private let region: String

    public init(kind: MediaKind, catalog: any CatalogService, now: @escaping @Sendable () -> Date = { Date() },
                region: String = NewReleases.deviceRegion) {
        self.kind = kind
        self.catalog = catalog
        self.now = now
        self.region = region
    }

    /// The titles for the slider at the top: New Series for TV (fresh shows rather than long-running ones), Popular
    /// for movies; whichever row loaded first when that one is missing. Only titles with artwork.
    public var featured: [CatalogItem] {
        let preferred = kind == .tv ? rows.first { $0.id == "c-\(CuratedList.newSeries.rawValue)" } : nil
        let source = (preferred?.items.isEmpty == false ? preferred : nil) ?? rows.first
        return Array((source?.items ?? []).filter { $0.backdropPath != nil }.prefix(6))
    }

    public static func genres(for kind: MediaKind) -> [Genre] {
        switch kind {
        case .tv:
            [Genre(id: 18, name: "Drama"), Genre(id: 35, name: "Comedy"), Genre(id: 80, name: "Crime"),
             Genre(id: 10765, name: "Sci-Fi & Fantasy"), Genre(id: 9648, name: "Mystery"),
             Genre(id: 16, name: "Animation"), Genre(id: 99, name: "Documentary"), Genre(id: 10764, name: "Reality")]
        default:
            [Genre(id: 28, name: "Action"), Genre(id: 35, name: "Comedy"), Genre(id: 18, name: "Drama"),
             Genre(id: 878, name: "Science Fiction"), Genre(id: 53, name: "Thriller"), Genre(id: 27, name: "Horror"),
             Genre(id: 16, name: "Animation"), Genre(id: 99, name: "Documentary")]
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let catalog = catalog
        let kind = kind
        let genres = Self.genres(for: kind)
        let today = now()
        let region = region
        async let fresh = NewReleases.load(kind, catalog: catalog, today: today, region: region)
        // Popular, the themed lists (New on Netflix, New Series, …), Top Rated, then genres.
        let curated = CuratedList.allCases.filter { $0.applies(to: kind) }
        let loaded = await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            group.addTask { (0, (try? await catalog.popular(kind)).map { CatalogRow(id: "popular", title: "Popular", items: $0) }) }
            for (offset, list) in curated.enumerated() {
                let query = list.query(for: kind, today: today)
                group.addTask {
                    (offset + 1, (try? await catalog.discover(kind, query: query))
                        .map { CatalogRow(id: "c-\(list.rawValue)", title: list.title, items: $0) })
                }
            }
            let afterCurated = curated.count + 1
            group.addTask { (afterCurated, (try? await catalog.topRated(kind)).map { CatalogRow(id: "top", title: "Top Rated", items: $0) }) }
            for (offset, genre) in genres.enumerated() {
                group.addTask {
                    (afterCurated + offset + 1, (try? await catalog.discover(kind, genreID: genre.id))
                        .map { CatalogRow(id: "g\(genre.id)", title: genre.name, items: $0) })
                }
            }
            var byOrder: [Int: CatalogRow] = [:]
            for await (order, row) in group { if let row, !row.items.isEmpty { byOrder[order] = row } }
            return byOrder.keys.sorted().compactMap { byOrder[$0] }
        }
        rows = loaded
        newReleases = await fresh
    }
}
