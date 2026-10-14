import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

private final class FakeChill: ChillCatalogService, @unchecked Sendable {
    var calls = 0
    var allowed: [Bool] = []
    var failing = false
    func combinedMovies(allowSettingsSwitch: Bool) async throws -> [ChillTitle] {
        calls += 1
        allowed.append(allowSettingsSwitch)
        if failing { throw AppError.transport("rss down") }
        return [ChillTitle(imdbID: nil, title: "Anora", year: 2024, kind: .movie, releaseDate: "2024-10-18", source: "RT"),
                ChillTitle(imdbID: nil, title: "Nobody Knows This", year: 2024, kind: .movie, source: "RT")]
    }
    func combinedShows() async throws -> [ChillTitle] {
        [ChillTitle(imdbID: nil, title: "Severance", year: 2022, kind: .tv, source: "ALL")]
    }
}

private struct FakeLatest: LatestTitlesSource {
    let kind: MediaKind
    func latestTitles() async throws -> [ChillTitle] {
        kind == .tv
            ? [ChillTitle(imdbID: nil, title: "Seinfeld", year: 1989, kind: .tv, source: "MYMOVIZ")]
            : [ChillTitle(imdbID: nil, title: "Animals", year: 2026, kind: .movie, source: "MYMOVIZ"),
               ChillTitle(imdbID: nil, title: "Anora", year: 2024, kind: .movie, source: "MYMOVIZ")]
    }
}

/// MyMoviz with a movie chill doesn't have.
private struct OnlyAnimals: LatestTitlesSource {
    let kind = MediaKind.movie
    func latestTitles() async throws -> [ChillTitle] {
        [ChillTitle(imdbID: nil, title: "Animals", year: 2026, kind: .movie, source: "MYMOVIZ")]
    }
}

@MainActor @Suite struct ChillFeedTests {
    let catalog = FakeCatalog(movieSearch: ["anora": [movie(1, "Anora")], "animals": [movie(2, "Animals", year: 2026)]],
                              tvSearch: ["severance": [show(95396, "Severance")], "seinfeld": [show(1400, "Seinfeld", year: 1989)]])

    @Test func mergesChillAndOtherListsAndMatchesThemToTMDB() async {
        let feed = ChillFeed(fileURL: nil)
        await feed.load(service: FakeChill(), extra: [FakeLatest(kind: .movie), FakeLatest(kind: .tv)], catalog: catalog)
        #expect(feed.movies.map(\.title) == ["Animals", "Anora"], "newest first; unmatched titles dropped; Anora once")
        #expect(feed.shows.map(\.tmdbID) == [95396, 1400], "chill's shows and MyMoviz's, newest first")
    }

    @Test func worksWithoutChill() async {
        let feed = ChillFeed(fileURL: nil)
        await feed.load(service: nil, extra: [FakeLatest(kind: .movie), FakeLatest(kind: .tv)], catalog: catalog)
        #expect(feed.movies.map(\.title) == ["Animals", "Anora"])
        #expect(feed.shows.map(\.title) == ["Seinfeld"])
    }

    @Test func keepsResultsForSixHoursAndOnDisk() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "chill-feed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let chill = FakeChill()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let feed = ChillFeed(fileURL: url)
        await feed.load(service: chill, catalog: catalog, now: start)
        await feed.load(service: chill, catalog: catalog, now: start.addingTimeInterval(3600))
        #expect(chill.calls == 1, "chill's settings aren't switched again within six hours")
        await feed.load(service: chill, catalog: catalog, now: start.addingTimeInterval(7 * 3600))
        #expect(chill.calls == 2)

        let reopened = ChillFeed(fileURL: url)
        await reopened.load(service: nil, catalog: nil, now: start.addingTimeInterval(7 * 3600 + 60))
        #expect(reopened.movies.map(\.title) == ["Anora"])
        #expect(reopened.shows.map(\.title) == ["Severance"])
    }

    @Test func openingTheAppAlwaysFetchesAgain() async {
        let chill = FakeChill()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let feed = ChillFeed(fileURL: nil)
        await feed.load(service: chill, catalog: catalog, force: true, now: start)
        await feed.load(service: chill, catalog: catalog, force: true, now: start.addingTimeInterval(60))
        #expect(chill.calls == 2)
    }

    @Test func settingsSwitchFallbackAtMostEverySixHours() async {
        let chill = FakeChill()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let feed = ChillFeed(fileURL: nil)
        await feed.load(service: chill, catalog: catalog, force: true, now: start)
        await feed.load(service: chill, catalog: catalog, force: true, now: start.addingTimeInterval(3600))
        await feed.load(service: chill, catalog: catalog, force: true, now: start.addingTimeInterval(7 * 3600))
        #expect(chill.allowed == [true, false, true])
    }

    @Test func keepsChillsLastListsWhenItCantBeRead() async {
        let chill = FakeChill()
        let feed = ChillFeed(fileURL: nil)
        await feed.load(service: chill, extra: [OnlyAnimals()], catalog: catalog, force: true)
        chill.failing = true
        await feed.load(service: chill, extra: [OnlyAnimals()], catalog: catalog, force: true)
        #expect(feed.movies.map(\.title) == ["Animals", "Anora"], "Anora (only on chill) is kept from chill's last list")
    }
}
