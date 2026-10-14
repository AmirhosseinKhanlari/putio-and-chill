import AMDBCore
import Foundation

/// The user's public IMDb watchlist (or list), as TMDB titles in IMDb's order. Shown at once from the last load, then
/// refreshed; each IMDb title is looked up on TMDB only once.
@Observable @MainActor
public final class IMDbWatchlistModel {
    public private(set) var items: [CatalogItem] = []
    public private(set) var isLoading = false
    /// Set when the last refresh failed (the saved list stays on screen).
    public private(set) var problem: String?
    public private(set) var isConnected = false
    public private(set) var lastLoaded: Date?

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private var ref: IMDbListRef?
    @ObservationIgnored private var service: (any IMDbListService)?
    @ObservationIgnored private var catalog: (any CatalogService)?
    @ObservationIgnored private var loadedCache = false
    /// How long a loaded watchlist is fresh before Home refreshes it.
    public static let freshFor: TimeInterval = 15 * 60

    public init(store: LocalStore) { self.store = store }

    public func configure(link: String?, service: any IMDbListService, catalog: (any CatalogService)?) {
        let newRef = link.flatMap(IMDbListRef.parse)
        if newRef != ref { lastLoaded = nil }
        ref = newRef
        self.service = service
        self.catalog = catalog
        isConnected = newRef != nil
        if newRef == nil {
            items = []
            problem = nil
        }
    }

    /// Refreshes from IMDb when it's stale (or always, with `force`).
    public func load(force: Bool = false, now: Date = Date()) async {
        guard let ref, let service, let catalog, !isLoading else { return }
        if !loadedCache {
            loadedCache = true
            if items.isEmpty { items = await store.snapshot.imdbWatchlist.map(\.catalogItem) }
        }
        if !force, let lastLoaded, now.timeIntervalSince(lastLoaded) < Self.freshFor { return }
        isLoading = true
        defer { isLoading = false }
        let titles: [IMDbListTitle]
        do {
            titles = try await service.titles(ref, limit: 1000)
        } catch IMDbWatchlistError.privateOrMissing {
            problem = "Your IMDb watchlist is private. Make it public on imdb.com to see it here."
            return
        } catch {
            problem = "Couldn't reach IMDb."
            return
        }
        var known = await store.snapshot.imdbMatches
        let missing = titles.map(\.imdbID).filter { known[$0] == nil }
        // Up to four TMDB lookups at a time.
        let found = await withTaskGroup(of: (String, CatalogItem?).self) { group in
            var results: [String: CatalogItem] = [:]
            var next = 0
            func add() {
                let id = missing[next]
                group.addTask { (id, try? await catalog.findByIMDb(id)) }
                next += 1
            }
            while next < min(4, missing.count) { add() }
            while let (id, item) = await group.next() {
                if let item { results[id] = item }
                if next < missing.count { add() }
            }
            return results
        }
        for (id, item) in found { known[id] = SavedTitle(item) }
        let list = titles.compactMap { known[$0.imdbID] }
        items = list.map(\.catalogItem)
        problem = nil
        lastLoaded = now
        let matches = known
        await store.update { state in
            state.imdbWatchlist = list
            state.imdbMatches = matches
        }
    }
}
