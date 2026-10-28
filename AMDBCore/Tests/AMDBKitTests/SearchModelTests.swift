import AMDBCore
import Testing
@testable import AMDBKit

@MainActor @Suite struct SearchModelTests {
    static let nolan = CatalogItem(tmdbID: 525, mediaType: .person, title: "Christopher Nolan",
                                   knownFor: [movie(157336, "Interstellar"), movie(27205, "Inception")])
    static let catalog = FakeCatalog(multi: [
        "dune": [movie(1, "Dune"), movie(2, "Dune: Part Two")],
        "nolan": [nolan, movie(27205, "Inception")],
    ])

    @Test func typingProducesResults() async throws {
        let search = SearchModel(catalog: Self.catalog, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "dune"
        try await waitUntil { !search.results.isEmpty && !search.isSearching }
        #expect(search.suggestions.map(\.tmdbID) == [1, 2])
        #expect(search.grid.map(\.tmdbID) == [1, 2])
    }

    @Test func peopleExpandToKnownForAndDedupe() async throws {
        let search = SearchModel(catalog: Self.catalog, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "nolan"
        try await waitUntil { !search.results.isEmpty }
        #expect(search.suggestions.map(\.tmdbID) == [27205])
        #expect(search.grid.map(\.tmdbID) == [157336, 27205])
    }

    @Test func clearingQueryClearsResults() async throws {
        let search = SearchModel(catalog: Self.catalog, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "dune"
        try await waitUntil { !search.results.isEmpty }
        search.query = "  "
        #expect(search.results.isEmpty)
        #expect(search.releaseQuery == nil)
    }

    /// TMDB unreachable: the spinner stops and the model says why, instead of searching forever.
    @Test func aFailedSearchStopsTheSpinner() async throws {
        var offline = Self.catalog
        offline.failAll = true
        let search = SearchModel(catalog: offline, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "dune"
        try await waitUntil { !search.isSearching }
        #expect(search.results.isEmpty)
        #expect(search.error == .transport("offline"))
        // Typing again clears the error.
        search.query = "dune part two"
        #expect(search.error == nil)
        try await waitUntil { !search.isSearching }
    }

    @Test func commitStoresRecentAndBuildsReleaseQuery() async {
        let store = LocalStore(fileURL: nil)
        let search = SearchModel(catalog: Self.catalog, store: store, debounce: .zero)
        search.query = " dune part two "
        #expect(search.releaseQuery == .text("dune part two"))
        await search.commit()
        await search.loadRecent()
        #expect(search.recent == ["dune part two"])
    }

    @Test func loadMoreAppendsNextPagesUntilTheEnd() async throws {
        var catalog = Self.catalog
        catalog.multiPages = ["dune": [2: [movie(3, "Dune 1984"), movie(1, "Dune")], 3: [movie(4, "Dune Prophecy")]]]
        catalog.multiTotalPages = 3
        let search = SearchModel(catalog: catalog, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "dune"
        try await waitUntil { search.results.count == 2 }
        #expect(search.canLoadMore)
        await search.loadMore()
        #expect(search.results.map(\.tmdbID) == [1, 2, 3])
        await search.loadMore()
        #expect(search.results.map(\.tmdbID) == [1, 2, 3, 4])
        #expect(!search.canLoadMore)
        await search.loadMore()
        #expect(search.results.count == 4)
    }

    @Test func newQueryResetsPaging() async throws {
        var catalog = Self.catalog
        catalog.multiPages = ["dune": [2: [movie(3, "Dune 1984")]]]
        catalog.multiTotalPages = 2
        let search = SearchModel(catalog: catalog, store: LocalStore(fileURL: nil), debounce: .zero)
        search.query = "dune"
        try await waitUntil { search.results.count == 2 }
        await search.loadMore()
        search.query = "nolan"
        try await waitUntil { search.results.map(\.tmdbID) == [525, 27205] }
        #expect(search.canLoadMore)
    }
}
