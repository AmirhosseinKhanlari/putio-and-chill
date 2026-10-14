import AMDBCore
import Testing
@testable import AMDBKit

@MainActor @Suite struct HomeModelTests {
    static let person = CatalogItem(tmdbID: 525, mediaType: .person, title: "Christopher Nolan")
    static let catalog = FakeCatalog(
        trendingItems: [movie(1, "A"), person, CatalogItem(tmdbID: 2, mediaType: .tv, title: "B")],
        popularMovies: [movie(3, "C")],
        popularShows: [show(4, "D")],
        details: [1: TitleDetail(item: movie(1, "A"), imdbID: "tt1", recommendations: [movie(5, "E")])])

    @Test func buildsHeroAndRows() async {
        let home = HomeModel(catalog: Self.catalog, store: LocalStore(fileURL: nil))
        await home.load()
        #expect(home.hero.map(\.tmdbID) == [1])
        #expect(home.rows.map(\.title) == ["Trending Now", "Popular Movies", "Popular TV"])
        #expect(home.rows[0].items.map(\.tmdbID) == [1, 2])
        #expect(home.error == nil)
        #expect(!home.isLoading)
    }

    @Test func addsBecauseYouWatched() async {
        let store = LocalStore(fileURL: nil)
        await store.update { $0.lastPlayed = PlayedTitle(tmdbID: 1, kind: .movie, title: "A") }
        let home = HomeModel(catalog: Self.catalog, store: store)
        await home.load()
        #expect(home.rows.map(\.title) == ["Trending Now", "Because you watched A", "Popular Movies", "Popular TV"])
        #expect(home.rows[1].items.map(\.tmdbID) == [5])
    }

    @Test func reportsErrorWhenEverythingFails() async {
        var offline = Self.catalog
        offline.failAll = true
        let home = HomeModel(catalog: offline, store: LocalStore(fileURL: nil))
        await home.load()
        #expect(home.error != nil)
        #expect(home.rows.isEmpty)
    }

    @Test func browseRowsKeepOrder() async {
        let browse = BrowseModel(kind: .movie, catalog: Self.catalog)
        await browse.load()
        #expect(browse.rows.map(\.title) == ["Popular", "New on Netflix", "New on Disney+", "Critically Acclaimed", "Top Rated"]
            + BrowseModel.genres(for: .movie).map(\.name))
        let shows = BrowseModel(kind: .tv, catalog: FakeCatalog(popularShows: [show(1, "Severance")]))
        await shows.load()
        #expect(shows.rows.prefix(6).map(\.title) == ["Popular", "New on Netflix", "New on Disney+", "New Series",
                                                        "Returning This Week", "Critically Acclaimed"])
        #expect(BrowseModel.genres(for: .tv).contains(Genre(id: 10765, name: "Sci-Fi & Fantasy")))
    }
}
