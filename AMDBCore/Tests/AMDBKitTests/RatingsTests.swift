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

    @Test func emptyResultsAreKeptBriefly() async {
        let cache = RatingsCache(fileURL: nil, ttl: 7 * 24 * 3600, emptyTTL: 3600)
        let t0 = Date(timeIntervalSince1970: 1000)
        await cache.store(Ratings(), for: "empty", now: t0)
        await cache.store(Ratings(imdb: 8), for: "full", now: t0)
        #expect(await cache.fresh("empty", now: t0.addingTimeInterval(60)) == Ratings())
        #expect(await cache.fresh("empty", now: t0.addingTimeInterval(3601)) == nil)
        #expect(await cache.fresh("full", now: t0.addingTimeInterval(3601))?.imdb == 8)
    }

    @Test func keysCarrySourceProviderAndKind() {
        #expect(RatingsCache.key(source: "mdblist", imdbID: "tt0903747", tmdbID: 1396, kind: .tv) == "mdblist:imdb:show:tt0903747")
        #expect(RatingsCache.key(source: "mdblist", imdbID: nil, tmdbID: 286801, kind: .tv) == "mdblist:tmdb:show:286801")
        #expect(RatingsCache.key(source: "mdblist", imdbID: "", tmdbID: 550, kind: .movie) == "mdblist:tmdb:movie:550")
        #expect(RatingsCache.key(source: "trakt", imdbID: "tt1", tmdbID: 1, kind: .movie) == "trakt:imdb:movie:tt1")
    }

    /// v2 kept week-long empty entries keyed by bare IMDb id; v3 is a new file with new keys, so none of them come back.
    @Test func oldCacheIsNotRead() async throws {
        #expect(RatingsCache.defaultURL().lastPathComponent == "ratings-v3.json")
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/ratings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = ["tt0903747": CachedRatings(ratings: Ratings(), fetchedAt: Date())]
        try JSONEncoder().encode(old).write(to: url)
        let key = RatingsCache.key(source: "mdblist", imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(await RatingsCache(fileURL: url).fresh(key) == nil)
    }
}

@MainActor @Suite struct AppRatingsTests {
    func makeModel(_ tokens: [TokenKey: String], bundledTMDB: String? = nil, ratings: FakeRatings = FakeRatings(),
                   catalogTokens: TokenLog = TokenLog(), trakt: FakeCharts? = nil,
                   cache: RatingsCache = RatingsCache(fileURL: nil),
                   bundledMDBList: String? = nil, ratingsKeys: TokenLog = TokenLog()) -> AppModel {
        let factory = ServiceFactory(
            makePutio: { _ in FakePutio() },
            makeCatalog: { token in catalogTokens.record(token); return FakeCatalog() },
            makeProvider: { config in FakeProvider(id: config.id) },
            makeRatings: { key in ratingsKeys.record(key); return ratings },
            makeCharts: { _ in trakt ?? FakeCharts() })
        return AppModel(tokens: InMemoryTokenStore(tokens), defaults: testDefaults(), store: LocalStore(fileURL: nil),
                        factory: factory, bundledTMDBToken: bundledTMDB, ratingsCache: cache,
                        bundledTraktClientID: trakt == nil ? nil : "CID", bundledMDBListKey: bundledMDBList)
    }

    @Test func bundledMDBListKeyGivesRatingsWithoutAKey() {
        let keys = TokenLog()
        let model = makeModel([.putio: "p", .tmdb: "t"], bundledMDBList: " BUNDLED\n", ratingsKeys: keys)
        #expect(model.hasRatings)
        #expect(model.usesBundledMDBList)
        #expect(keys.all.last == "BUNDLED")
    }

    @Test func savedMDBListKeyWinsOverBundled() {
        let keys = TokenLog()
        _ = makeModel([.putio: "p", .tmdb: "t", .mdblist: "MINE"], bundledMDBList: "BUNDLED", ratingsKeys: keys)
        #expect(keys.all.last == "MINE")
    }

    @Test func emptyBundledMDBListKeyIsIgnored() {
        let model = makeModel([.putio: "p", .tmdb: "t"], bundledMDBList: "")
        #expect(!model.hasRatings)
        #expect(!model.usesBundledMDBList)
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
        #expect(!without.canFetchRatings)
        #expect(await without.ratings(imdbID: "tt1", tmdbID: 1, kind: .movie) == nil)

        let with = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: fake)
        #expect(with.hasRatings)
        #expect(await with.ratings(imdbID: "tt1", tmdbID: 1, kind: .movie)?.tomatoes == 91)
        #expect(await with.ratings(imdbID: "tt1", tmdbID: 1, kind: .movie)?.popcorn == 88)
        #expect(fake.calls == 1)
        #expect(fake.lookups.first?.imdbID == "tt1")
        #expect(fake.lookups.first?.tmdbID == 1)
    }

    @Test func failedLookupsReturnNil() async {
        let fake = FakeRatings()
        fake.fail = true
        let model = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: fake)
        #expect(await model.ratings(imdbID: "tt1", tmdbID: 1, kind: .movie) == nil)
        await #expect(throws: AppError.self) { try await model.validateMDBList("bad") }
    }

    @Test func titleModelLoadsRatings() async {
        let item = movie(693134, "Dune: Part Two")
        let catalog = FakeCatalog(details: [693134: TitleDetail(item: item, imdbID: "tt15239678")])
        let store = LocalStore(fileURL: nil)
        let title = TitleModel(item: item, catalog: catalog, library: LibraryIndex(store: store),
                               transfers: TransferMonitor(store: store),
                               ratings: { imdbID, tmdbID, kind in
                                   imdbID == "tt15239678" && tmdbID == 693134 && kind == .movie ? Ratings(imdb: 8.5) : nil
                               })
        await title.load()
        #expect(title.ratings?.imdb == 8.5)
    }

    /// Shows TMDB has no IMDb id for still get scores, looked up by TMDB id.
    @Test func titleModelAsksForShowsWithoutIMDbID() async {
        let item = show(286801, "Monster: The Ed Gein Story")
        let catalog = FakeCatalog(details: [286801: TitleDetail(item: item, imdbID: nil)])
        let store = LocalStore(fileURL: nil)
        let title = TitleModel(item: item, catalog: catalog, library: LibraryIndex(store: store),
                               transfers: TransferMonitor(store: store),
                               ratings: { imdbID, tmdbID, kind in
                                   imdbID == nil && tmdbID == 286801 && kind == .tv ? Ratings(imdb: 7.1) : nil
                               })
        await title.load()
        #expect(title.ratings?.imdb == 7.1)
    }

    @Test func emptyAnswersAreAskedAgainAfterTheShortTTL() async {
        let empty = FakeRatings(result: Ratings())
        let model = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: empty,
                              cache: RatingsCache(fileURL: nil, emptyTTL: 0))
        #expect(await model.ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)?.isEmpty == true)
        _ = await model.ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(empty.calls == 2)

        let full = FakeRatings()
        let cached = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], ratings: full,
                               cache: RatingsCache(fileURL: nil, emptyTTL: 0))
        _ = await cached.ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        _ = await cached.ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(full.calls == 1)
    }

    @Test func traktScoreJoinsMDBListAndWorksWithoutAKey() async {
        let trakt = FakeCharts()
        trakt.traktRating = 9.3
        let both = makeModel([.putio: "p", .tmdb: "t", .mdblist: "m"], trakt: trakt)
        let merged = await both.ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(merged == Ratings(imdb: 8.1, tomatoes: 91, popcorn: 88, trakt: 9.3))

        let traktOnly = makeModel([.putio: "p", .tmdb: "t"], trakt: trakt)
        #expect(!traktOnly.hasRatings)
        #expect(traktOnly.canFetchRatings)
        #expect(await traktOnly.ratings(imdbID: nil, tmdbID: 286801, kind: .tv) == Ratings(trakt: 9.3))
        _ = await traktOnly.ratings(imdbID: nil, tmdbID: 286801, kind: .tv)
        #expect(trakt.ratingCalls == 2)
    }
}
