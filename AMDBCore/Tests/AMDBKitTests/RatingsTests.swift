import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct RatingsCacheTests {
    @Test func expiresAfterTTLAndPersists() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/ratings.json")
        let cache = RatingsCache(fileURL: url, ttl: 100)
        let t0 = Date(timeIntervalSince1970: 1000)
        await cache.store(Ratings(imdb: 7.5), for: "tt1", now: t0)
        #expect(await cache.fresh("tt1", now: t0.addingTimeInterval(50))?.imdb == 7.5)
        #expect(await cache.fresh("tt1", now: t0.addingTimeInterval(150)) == nil)
        #expect(await RatingsCache(fileURL: url, ttl: 100).fresh("tt1", now: t0.addingTimeInterval(10))?.imdb == 7.5)
    }
}

@MainActor @Suite struct AppRatingsTests {
    func makeModel(_ tokens: [TokenKey: String], bundledTMDB: String? = nil, ratings: FakeRatings = FakeRatings(),
                   catalogTokens: TokenLog = TokenLog()) -> AppModel {
        let factory = ServiceFactory(
            makePutio: { _ in FakePutio() },
            makeCatalog: { token in catalogTokens.record(token); return FakeCatalog() },
            makeProvider: { config, _ in FakeProvider(id: config.id) },
            makeRatings: { _ in ratings })
        return AppModel(tokens: InMemoryTokenStore(tokens), defaults: testDefaults(), store: LocalStore(fileURL: nil),
                        factory: factory, bundledTMDBToken: bundledTMDB, ratingsCache: RatingsCache(fileURL: nil))
    }

    @Test func bundledTMDBTokenMakesCatalogReady() {
        let log = TokenLog()
        let model = makeModel([.putio: "p"], bundledTMDB: "BUNDLED", catalogTokens: log)
        #expect(model.isReady)
        #expect(model.usesBundledTMDB)
        #expect(log.all.last == "BUNDLED")
    }

    @Test func userTokenWinsOverBundled() {
        let log = TokenLog()
        _ = makeModel([.putio: "p", .tmdb: "MINE"], bundledTMDB: "BUNDLED", catalogTokens: log)
        #expect(log.all.last == "MINE")
    }

    @Test func emptyBundledTokenIsIgnored() {
        let model = makeModel([.putio: "p"], bundledTMDB: "")
        #expect(!model.isReady)
        #expect(!model.usesBundledTMDB)
    }

    @Test func ratingsNeedKeyAndAreCached() async {
        let fake = FakeRatings()
        let without = makeModel([.putio: "p", .tmdb: "t"], ratings: fake)
        #expect(!without.hasRatings)
        #expect(await without.ratings(imdbID: "tt1", kind: .movie) == nil)

        let with = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: fake)
        #expect(with.hasRatings)
        #expect(await with.ratings(imdbID: "tt1", kind: .movie)?.tomatoes == 91)
        #expect(await with.ratings(imdbID: "tt1", kind: .movie)?.popcorn == 88)
        #expect(fake.calls == 1)
    }

    @Test func failedLookupsReturnNil() async {
        let fake = FakeRatings()
        fake.fail = true
        let model = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: fake)
        #expect(await model.ratings(imdbID: "tt1", kind: .movie) == nil)
        await #expect(throws: AppError.self) { try await model.validateMDBList("bad") }
    }

    @Test func titleModelLoadsRatings() async {
        let item = movie(693134, "Dune: Part Two")
        let catalog = FakeCatalog(details: [693134: TitleDetail(item: item, imdbID: "tt15239678")])
        let store = LocalStore(fileURL: nil)
        let title = TitleModel(item: item, catalog: catalog, library: LibraryIndex(store: store),
                               transfers: TransferMonitor(store: store),
                               ratings: { imdbID, kind in imdbID == "tt15239678" && kind == .movie ? Ratings(imdb: 8.5) : nil })
        await title.load()
        #expect(title.ratings?.imdb == 8.5)
    }
}
