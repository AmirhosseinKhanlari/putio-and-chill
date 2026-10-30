import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor
@Suite struct EpisodeRatingsTests {
    @Test func titleModelLoadsScoresForSelectedSeason() async throws {
        let store = LocalStore(fileURL: nil)
        let show = CatalogItem(tmdbID: 95396, mediaType: .tv, title: "Severance", year: 2022)
        var catalog = FakeCatalog()
        catalog.details[95396] = TitleDetail(item: show, imdbID: "tt11280740", seasons: [
            SeasonSummary(number: 1, name: "Season 1", episodeCount: 2, posterPath: nil),
            SeasonSummary(number: 2, name: "Season 2", episodeCount: 2, posterPath: nil),
        ])
        catalog.seasons = [1: [Episode(number: 1, name: "Good News About Hell")], 2: [Episode(number: 2, name: "Goodbye")]]
        var asked: [String] = []
        let model = TitleModel(item: show, catalog: catalog, library: LibraryIndex(store: store),
                               transfers: TransferMonitor(store: store),
                               episodeRatings: { imdbID, season in
                                   asked.append("\(imdbID)-\(season)")
                                   return season == 1 ? [1: EpisodeRating(rating: 8.1, votes: 900)] : [2: EpisodeRating(rating: 9.4, votes: 50)]
                               })
        await model.load()
        #expect(model.episodeRatings[1]?.rating == 8.1)
        await model.selectSeason(2)
        #expect(model.episodeRatings[1] == nil)
        #expect(model.episodeRatings[2]?.rating == 9.4)
        #expect(asked == ["tt11280740-1", "tt11280740-2"])
    }

    @Test func appModelCachesSeasonRatings() async throws {
        let service = CountingEpisodeRatings()
        let factory = ServiceFactory(makePutio: { _ in fatalError() }, makeCatalog: { _ in FakeCatalog() },
                                     makeProvider: { _ in nil }, episodeRatings: service)
        let app = AppModel(tokens: InMemoryTokenStore(), store: LocalStore(fileURL: nil), factory: factory)
        _ = await app.episodeRatings(seriesIMDbID: "tt1", season: 1)
        let second = await app.episodeRatings(seriesIMDbID: "tt1", season: 1)
        #expect(second[3]?.rating == 7.5)
        #expect(service.calls == 1)
    }
}

private final class CountingEpisodeRatings: EpisodeRatingsService, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func ratings(seriesIMDbID: String, season: Int) async throws -> [Int: EpisodeRating] {
        lock.withLock { count += 1 }
        return [3: EpisodeRating(rating: 7.5, votes: 10)]
    }
}
