import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

private final class FakeLatest: LatestTitlesSource, @unchecked Sendable {
    let kind: MediaKind
    var calls = 0
    var failing = false
    init(kind: MediaKind) { self.kind = kind }
    func latestTitles() async throws -> [LatestTitle] {
        calls += 1
        if failing { throw AppError.transport("mymoviz down") }
        return kind == .tv
            ? [LatestTitle(imdbID: nil, title: "Seinfeld", year: 1989, kind: .tv, source: "MYMOVIZ"),
               LatestTitle(imdbID: nil, title: "Severance", year: 2022, kind: .tv, source: "MYMOVIZ")]
            : [LatestTitle(imdbID: nil, title: "Anora", year: 2024, kind: .movie, source: "MYMOVIZ"),
               LatestTitle(imdbID: nil, title: "Animals", year: 2026, kind: .movie, source: "MYMOVIZ"),
               LatestTitle(imdbID: nil, title: "Nobody Knows This", year: 2024, kind: .movie, source: "MYMOVIZ"),
               LatestTitle(imdbID: nil, title: "Anora", year: 2024, kind: .movie, source: "MYMOVIZ")]
    }
}

@MainActor @Suite struct LatestFeedTests {
    let catalog = FakeCatalog(movieSearch: ["anora": [movie(1, "Anora")], "animals": [movie(2, "Animals", year: 2026)]],
                              tvSearch: ["severance": [show(95396, "Severance")], "seinfeld": [show(1400, "Seinfeld", year: 1989)]])

    @Test func matchesMyMovizListsToTMDBNewestFirst() async {
        let feed = LatestFeed(fileURL: nil)
        await feed.load(sources: [FakeLatest(kind: .movie), FakeLatest(kind: .tv)], catalog: catalog)
        #expect(feed.movies.map(\.title) == ["Animals", "Anora"], "newest first; unmatched titles dropped; Anora once")
        #expect(feed.shows.map(\.tmdbID) == [95396, 1400])
    }

    @Test func keepsResultsForSixHoursAndOnDisk() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "latest-feed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let movies = FakeLatest(kind: .movie)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let feed = LatestFeed(fileURL: url)
        await feed.load(sources: [movies], catalog: catalog, now: start)
        await feed.load(sources: [movies], catalog: catalog, now: start.addingTimeInterval(3600))
        #expect(movies.calls == 1)
        await feed.load(sources: [movies], catalog: catalog, now: start.addingTimeInterval(7 * 3600))
        #expect(movies.calls == 2)

        let reopened = LatestFeed(fileURL: url)
        await reopened.load(sources: [], catalog: nil, now: start.addingTimeInterval(7 * 3600 + 60))
        #expect(reopened.movies.map(\.title) == ["Animals", "Anora"])
    }

    @Test func openingTheAppAlwaysFetchesAgain() async {
        let movies = FakeLatest(kind: .movie)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let feed = LatestFeed(fileURL: nil)
        await feed.load(sources: [movies], catalog: catalog, force: true, now: start)
        await feed.load(sources: [movies], catalog: catalog, force: true, now: start.addingTimeInterval(60))
        #expect(movies.calls == 2)
    }

    @Test func keepsTheLastRowsWhenTheListCantBeRead() async {
        let movies = FakeLatest(kind: .movie)
        let feed = LatestFeed(fileURL: nil)
        await feed.load(sources: [movies], catalog: catalog, force: true)
        movies.failing = true
        await feed.load(sources: [movies], catalog: catalog, force: true)
        #expect(feed.movies.map(\.title) == ["Animals", "Anora"])
    }

    /// A snapshot written by the version with chill (extra fields, old file name) never breaks anything.
    @Test func oldSnapshotIsRemovedOnceAndTheChillTokenDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "retired-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appending(path: "chill-feed.json")
        try Data(#"{"updatedAt":0,"movies":[],"shows":[],"chillMovies":[],"lastSettingsSwitch":0}"#.utf8).write(to: old)
        let defaults = testDefaults()
        var removed: [String] = []
        RetiredData.removeOnce(defaults: defaults, directory: directory) { removed.append($0); return true }
        #expect(!FileManager.default.fileExists(atPath: old.path()))
        #expect(removed == ["chill"])
        RetiredData.removeOnce(defaults: defaults, directory: directory) { removed.append($0); return true }
        #expect(removed == ["chill"], "only the first launch")
    }

    @Test func aRefusedTokenDeleteIsTriedAgainNextLaunch() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "retired-\(UUID())")
        let defaults = testDefaults()
        var attempts = 0
        RetiredData.removeOnce(defaults: defaults, directory: directory) { _ in attempts += 1; return false }
        RetiredData.removeOnce(defaults: defaults, directory: directory) { _ in attempts += 1; return true }
        #expect(attempts == 2, "retried after the refusal")
        RetiredData.removeOnce(defaults: defaults, directory: directory) { _ in attempts += 1; return true }
        #expect(attempts == 2, "done once it worked")
    }

    @Test func aFailedListKeepsItsRememberedMatchesWhenOthersAreTrimmed() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "latest-feed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A snapshot with 700 remembered matches, among them the two TV shows.
        var resolved: [String: FeedTitle] = [:]
        for i in 0..<700 { resolved["filler\(i)"] = FeedTitle(movie(10_000 + i, "Filler \(i)")) }
        let tv = LatestFeed(fileURL: nil)
        await tv.load(sources: [FakeLatest(kind: .tv)], catalog: catalog)
        for item in tv.shows {
            resolved[LatestTitle(imdbID: nil, title: item.title, year: item.year, kind: .tv, source: "").mergeKey] = FeedTitle(item)
        }
        let snapshot = LatestFeedSnapshot(updatedAt: .distantPast, movies: [], shows: tv.shows.map(FeedTitle.init), resolved: resolved)
        try? JSONEncoder().encode(snapshot).write(to: url)

        let shows = FakeLatest(kind: .tv)
        shows.failing = true
        let feed = LatestFeed(fileURL: url)
        await feed.load(sources: [FakeLatest(kind: .movie), shows], catalog: catalog, force: true)
        #expect(feed.shows.map(\.tmdbID) == [95396, 1400], "the failed list keeps its row")
        shows.failing = false
        let empty = FakeCatalog(movieSearch: [:], tvSearch: [:])
        await feed.load(sources: [shows], catalog: empty, force: true, now: Date().addingTimeInterval(1))
        #expect(feed.shows.map(\.tmdbID) == [95396, 1400], "matches were kept, so no lookup was needed")
    }

    @Test func snapshotWithUnknownFieldsStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "latest-feed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"updatedAt":0,"movies":[{"tmdbID":1,"kind":"movie","title":"Anora","overview":""}],"shows":[],"chillMovies":[]}"#
        try Data(json.utf8).write(to: url)
        let feed = LatestFeed(fileURL: url)
        await feed.load(sources: [], catalog: nil)
        #expect(feed.movies.map(\.title) == ["Anora"])
    }

    @Test func combineDropsDuplicatesAndPutsNewestYearsFirst() {
        let a = [LatestTitle(imdbID: "tt1", title: "Old", year: 2001, kind: .movie, source: "A"),
                 LatestTitle(imdbID: nil, title: "Undated", year: nil, kind: .movie, source: "A")]
        let b = [LatestTitle(imdbID: "tt1", title: "Old (again)", year: 2001, kind: .movie, source: "B"),
                 LatestTitle(imdbID: nil, title: "New", year: 2026, kind: .movie, source: "B")]
        #expect(LatestTitle.combine([a, b]).map(\.title) == ["New", "Old", "Undated"])
    }
}
