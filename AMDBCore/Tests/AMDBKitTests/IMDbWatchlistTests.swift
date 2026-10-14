import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct IMDbWatchlistTests {
    struct FakeList: IMDbListService {
        var titles: [IMDbListTitle] = []
        var isPrivate = false
        func titles(_ ref: IMDbListRef, limit: Int) async throws -> [IMDbListTitle] {
            if isPrivate { throw IMDbWatchlistError.privateOrMissing }
            return titles
        }
    }

    let locke = CatalogItem(tmdbID: 209274, mediaType: .movie, title: "Locke")
    let breakingBad = CatalogItem(tmdbID: 1396, mediaType: .tv, title: "Breaking Bad")

    func list() -> FakeList {
        FakeList(titles: [IMDbListTitle(imdbID: "tt0903747", title: "Breaking Bad", kind: "tvSeries", year: 2008),
                          IMDbListTitle(imdbID: "tt9999999", title: "Unknown", kind: "movie", year: nil),
                          IMDbListTitle(imdbID: "tt2692904", title: "Locke", kind: "movie", year: 2013)])
    }

    @Test func matchesTitlesInIMDbOrderAndRemembersThem() async {
        var catalog = FakeCatalog()
        catalog.imdb = ["tt0903747": breakingBad, "tt2692904": locke]
        let store = LocalStore(fileURL: nil)
        let model = IMDbWatchlistModel(store: store)
        model.configure(link: "https://www.imdb.com/user/ur123456/watchlist", service: list(), catalog: catalog)
        await model.load()
        #expect(model.items.map(\.title) == ["Breaking Bad", "Locke"])
        #expect(await store.snapshot.imdbMatches["tt2692904"]?.tmdbID == 209274)

        // Next launch: the saved list shows at once, and known titles aren't looked up again.
        catalog.failAll = true
        let again = IMDbWatchlistModel(store: store)
        again.configure(link: "ur123456", service: list(), catalog: catalog)
        await again.load()
        #expect(again.items.map(\.title) == ["Breaking Bad", "Locke"])
        #expect(again.problem == nil)
    }

    @Test func aPrivateWatchlistKeepsWhatWasShownAndExplains() async {
        let model = IMDbWatchlistModel(store: LocalStore(fileURL: nil))
        model.configure(link: "ur123456", service: FakeList(isPrivate: true), catalog: FakeCatalog())
        await model.load()
        #expect(model.items.isEmpty)
        #expect(model.problem?.contains("private") == true)
    }

    @Test func freshListsAreNotReloaded() async {
        var catalog = FakeCatalog()
        catalog.imdb = ["tt2692904": locke]
        let model = IMDbWatchlistModel(store: LocalStore(fileURL: nil))
        model.configure(link: "ur123456", service: list(), catalog: catalog)
        let now = Date()
        await model.load(now: now)
        #expect(model.lastLoaded == now)
        await model.load(now: now.addingTimeInterval(60))
        #expect(model.lastLoaded == now)
        await model.load(now: now.addingTimeInterval(IMDbWatchlistModel.freshFor + 1))
        #expect(model.lastLoaded != now)
    }

    @Test func disconnectingClearsIt() async {
        var catalog = FakeCatalog()
        catalog.imdb = ["tt2692904": locke]
        let model = IMDbWatchlistModel(store: LocalStore(fileURL: nil))
        model.configure(link: "ur123456", service: list(), catalog: catalog)
        await model.load()
        model.configure(link: nil, service: list(), catalog: catalog)
        #expect(!model.isConnected)
        #expect(model.items.isEmpty)
    }
}
