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

    @Test func commitStoresRecentAndBuildsReleaseQuery() async {
        let store = LocalStore(fileURL: nil)
        let search = SearchModel(catalog: Self.catalog, store: store, debounce: .zero)
        search.query = " dune part two "
        #expect(search.releaseQuery == .text("dune part two"))
        await search.commit()
        await search.loadRecent()
        #expect(search.recent == ["dune part two"])
    }
}
