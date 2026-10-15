import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct BrowseFeaturedTests {
    /// TV Shows' slider shows New Series (fresh shows), Movies' shows Popular.
    @Test func showsFeatureNewSeries() async {
        var catalog = FakeCatalog()
        let popular = [CatalogItem(tmdbID: 1, mediaType: .tv, title: "Old Favourite", backdropPath: "/a.jpg")]
        catalog.popularShows = popular
        catalog.popularMovies = [CatalogItem(tmdbID: 2, mediaType: .movie, title: "Big Movie", backdropPath: "/b.jpg")]
        let browse = BrowseModel(kind: .tv, catalog: catalog)
        await browse.load()
        // The fake's discover answers every themed list with popular titles; New Series is picked by its row.
        #expect(browse.rows.contains { $0.id == "c-newSeries" })
        #expect(browse.featured.map(\.title) == browse.rows.first { $0.id == "c-newSeries" }?.items.filter { $0.backdropPath != nil }.prefix(6).map(\.title))
        let movies = BrowseModel(kind: .movie, catalog: catalog)
        await movies.load()
        #expect(movies.featured.map(\.title) == ["Big Movie"])
    }
}
