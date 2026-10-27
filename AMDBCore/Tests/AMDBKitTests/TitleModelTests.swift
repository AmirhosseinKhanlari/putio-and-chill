import AMDBCore
import Testing
@testable import AMDBKit

@MainActor @Suite struct TitleModelTests {
    static let dune = movie(693134, "Dune: Part Two", year: 2024)
    static let severance = show(95396, "Severance")
    static let catalog = FakeCatalog(
        details: [693134: TitleDetail(item: dune, imdbID: "tt15239678"),
                  95396: TitleDetail(item: severance, imdbID: "tt11280740",
                                     seasons: [SeasonSummary(number: 1, name: "Season 1", episodeCount: 9, posterPath: nil),
                                               SeasonSummary(number: 2, name: "Season 2", episodeCount: 10, posterPath: nil)])],
        seasons: [1: [Episode(number: 1, name: "Good News About Hell")], 2: [Episode(number: 4, name: "Woe's Hollow")]])

    func rig() -> (TitleModel, LibraryIndex, TransferMonitor, FakePutio) {
        let store = LocalStore(fileURL: nil)
        let putio = FakePutio()
        let library = LibraryIndex(store: store)
        library.configure(putio: putio, catalog: Self.catalog)
        let transfers = TransferMonitor(store: store, pollInterval: .seconds(3600))
        transfers.configure(putio: putio, library: library)
        return (TitleModel(item: Self.dune, catalog: Self.catalog, library: library, transfers: transfers), library, transfers, putio)
    }

    /// A title that couldn't load can be tried again from the page: the error clears once it loads.
    @Test func loadCanBeTriedAgainAfterAFailure() async {
        var catalog = Self.catalog
        let outage = FakeCatalog.Outage()
        catalog.outage = outage
        let store = LocalStore(fileURL: nil)
        let library = LibraryIndex(store: store)
        let model = TitleModel(item: Self.dune, catalog: catalog, library: library,
                               transfers: TransferMonitor(store: store, pollInterval: .seconds(3600)))
        await model.load()
        #expect(model.detail == nil)
        #expect(model.error != nil)
        #expect(!model.isLoading)

        outage.isOn = false
        await model.load()
        #expect(model.detail?.imdbID == "tt15239678")
        #expect(model.error == nil)
    }

    @Test func movieActionsFollowLibraryAndTransfers() async throws {
        let (model, library, transfers, _) = rig()
        await model.load()
        #expect(model.detail?.imdbID == "tt15239678")
        #expect(model.action() == .get)

        let release = makeRelease("a", seeders: 5, name: "Dune.Part.Two.2024.1080p")
        let tracked = try await transfers.send(release, target: model.target())
        transfers.stop()
        #expect(model.action() == .downloading(transfers.latest(tmdbID: 693134)!))
        try await transfers.cancel(tracked.id)

        let file = PutioFile(id: 9, name: "Dune.mkv", fileType: "VIDEO", startFrom: 0)
        await library.record(file: file, match: LibraryMatch(tmdbID: 693134, mediaType: .movie, season: nil, episode: nil, confidence: 1))
        guard case .play = model.action() else { Issue.record("expected play"); return }
        library.noteProgress(fileID: 9, seconds: 4360)
        guard case let .resume(_, seconds) = model.action() else { Issue.record("expected resume"); return }
        #expect(seconds == 4360)
    }

    @Test func movieQueryAndTarget() async {
        let (model, _, _, _) = rig()
        await model.load()
        #expect(model.query() == .movie(imdbID: "tt15239678", title: "Dune: Part Two", year: 2024))
        #expect(model.target().kind == .movie)
    }

    @Test func tvLoadsFirstSeasonAndBuildsEpisodeQuery() async {
        let store = LocalStore(fileURL: nil)
        let library = LibraryIndex(store: store)
        let model = TitleModel(item: Self.severance, catalog: Self.catalog, library: library, transfers: TransferMonitor(store: store))
        await model.load()
        #expect(model.selectedSeason == 1)
        #expect(model.episodes.map(\.number) == [1])
        await model.selectSeason(2)
        #expect(model.episodes.map(\.number) == [4])
        #expect(model.query(season: 2, episode: 4) == .episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 4))
        #expect(model.query(season: 2) == .season(imdbID: "tt11280740", title: "Severance", season: 2))
        let tv = model.target(season: 2, episode: 4)
        #expect(FolderLayout.standard.displayPath(kind: tv.kind, title: tv.title, season: tv.season) == "TV Series/Severance/Season 2")
    }

    /// TMDB has shows without an IMDb id ("Monster: The Ed Gein Story"): Get, Get season and Versions still have a query.
    @Test func showWithoutIMDbIDIsSearchedByTitle() async {
        let edGein = show(286801, "Monster: The Ed Gein Story", year: 2025)
        let catalog = FakeCatalog(details: [286801: TitleDetail(item: edGein, imdbID: nil,
                                                                seasons: [SeasonSummary(number: 1, name: "Miniseries", episodeCount: 8, posterPath: nil)])],
                                  seasons: [1: [Episode(number: 1, name: "Mother")]])
        let store = LocalStore(fileURL: nil)
        let model = TitleModel(item: edGein, catalog: catalog, library: LibraryIndex(store: store), transfers: TransferMonitor(store: store))
        #expect(model.query(season: 1, episode: 1) == nil)
        #expect(model.queryUnavailableMessage.contains("loading"))
        await model.load()
        #expect(model.query(season: 1, episode: 1) == .episode(imdbID: nil, title: "Monster: The Ed Gein Story", season: 1, episode: 1))
        #expect(model.query(season: 1) == .season(imdbID: nil, title: "Monster: The Ed Gein Story", season: 1))
        #expect(model.query(season: 1)?.searchText == "Monster The Ed Gein Story S01")
    }

    @Test func movieWithoutIMDbIDIsSearchedByTitle() async {
        let film = movie(1, "Some Film", year: 2025)
        let catalog = FakeCatalog(details: [1: TitleDetail(item: film, imdbID: nil)])
        let store = LocalStore(fileURL: nil)
        let model = TitleModel(item: film, catalog: catalog, library: LibraryIndex(store: store), transfers: TransferMonitor(store: store))
        await model.load()
        #expect(model.query() == .movie(imdbID: nil, title: "Some Film", year: 2025))
    }

    @Test func showOpensOnTheSeasonBeingWatched() async {
        let store = LocalStore(fileURL: nil)
        let library = LibraryIndex(store: store)
        library.configure(putio: FakePutio(), catalog: Self.catalog)
        await library.record(file: PutioFile(id: 21, name: "Severance.S02E04.mkv", fileType: "VIDEO", startFrom: 1250),
                             match: LibraryMatch(tmdbID: 95396, mediaType: .tv, season: 2, episode: 4, confidence: 1))
        let model = TitleModel(item: Self.severance, catalog: Self.catalog, library: library, transfers: TransferMonitor(store: store))
        await model.load()
        #expect(model.selectedSeason == 2)
        #expect(model.episodes.map(\.number) == [4])
    }

    @Test func missingDetailReportsError() async {
        let store = LocalStore(fileURL: nil)
        let model = TitleModel(item: movie(1, "Unknown"), catalog: Self.catalog, library: LibraryIndex(store: store),
                               transfers: TransferMonitor(store: store))
        await model.load()
        #expect(model.error != nil)
        #expect(model.query() == nil)
    }
}
