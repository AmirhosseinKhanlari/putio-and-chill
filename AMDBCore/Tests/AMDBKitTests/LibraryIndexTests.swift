import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct LibraryIndexTests {
    static func tree() -> FakePutio {
        let putio = FakePutio()
        putio.add(PutioFile(id: 1, name: "Movies", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 10, name: "Dune.Part.Two.2024.1080p.mkv", fileType: "VIDEO", size: 3_000_000_000,
                            createdAt: "2026-10-02T00:00:00", updatedAt: "2026-10-05T00:00:00", startFrom: 120), to: 0)
        putio.add(PutioFile(id: 2, name: "Severance S02", fileType: "FOLDER"), to: 1)
        putio.add(PutioFile(id: 11, name: "Heat.1995.mkv", fileType: "VIDEO", size: 2_000_000_000,
                            createdAt: "2026-10-01T00:00:00", startFrom: 0), to: 1)
        putio.add(PutioFile(id: 12, name: "Severance.S02E04.1080p.mkv", fileType: "VIDEO", size: 2_000_000_000,
                            createdAt: "2026-10-03T00:00:00", updatedAt: "2026-10-06T00:00:00", startFrom: 900), to: 2)
        putio.add(PutioFile(id: 13, name: "sample.mkv", fileType: "VIDEO", size: 10_000_000), to: 2)
        putio.add(PutioFile(id: 14, name: "Episode 5.mkv", fileType: "VIDEO", size: 2_000_000_000), to: 2)
        return putio
    }

    static let catalog = FakeCatalog(
        movieSearch: ["dune part two": [movie(693134, "Dune: Part Two", year: 2024)],
                      "heat": [movie(949, "Heat", year: 1995)]],
        tvSearch: ["severance": [show(95396, "Severance")]])

    func makeIndex(catalog: FakeCatalog = LibraryIndexTests.catalog, store: LocalStore = LocalStore(fileURL: nil)) -> LibraryIndex {
        let index = LibraryIndex(store: store)
        index.configure(putio: Self.tree(), catalog: catalog)
        return index
    }

    @Test func refreshFindsVideosSkipsSamplesAndMatches() async {
        let index = makeIndex()
        await index.refresh()
        #expect(index.entries.map(\.id) == [12, 10, 11, 14])
        #expect(index.entries.first { $0.id == 10 }?.match?.tmdbID == 693134)
        #expect(index.entries.first { $0.id == 12 }?.match?.episode == 4)
        #expect(index.entries.first { $0.id == 14 }?.match?.tmdbID == 95396)
        #expect(index.entries.first { $0.id == 14 }?.match?.season == 2)
        #expect(index.lastError == nil)
    }

    @Test func continueWatchingAndRecentlyAdded() async {
        let index = makeIndex()
        await index.refresh()
        #expect(index.continueWatching.map(\.id) == [12, 10])
        #expect(index.recentlyAdded.first?.id == 12)
        index.noteProgress(fileID: 11, seconds: 600)
        #expect(index.continueWatching.first?.id == 11)
        #expect(index.resumeSeconds(for: index.entries.first { $0.id == 11 }!) == 600)
        index.noteProgress(fileID: 12, seconds: 0)
        #expect(!index.continueWatching.contains { $0.id == 12 })
    }

    @Test func recentlyAddedByKindShowsEachShowOnce() async {
        let index = makeIndex()
        await index.refresh()
        #expect(index.recentlyAdded(.movie).map(\.id) == [10, 11])
        #expect(index.recentlyAdded(.tv).map(\.id) == [12])
    }

    @Test func filesWaitingForAMatchAreNotShown() async {
        var slow = Self.catalog
        slow.searchDelay = .milliseconds(150)
        let index = makeIndex(catalog: slow)
        let refresh = Task { await index.refresh() }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(index.pendingMatches > 0, "still matching")
        #expect(index.entries.allSatisfy { $0.match != nil }, "no raw file names while matching")
        await refresh.value
        #expect(index.pendingMatches == 0)
        #expect(index.entries.map(\.id).sorted() == [10, 11, 12, 14])
    }

    @Test func continueWatchingShowsEachTitleOnce() async {
        let putio = Self.tree()
        // A second, older-watched version of Dune and a started episode next to S02E04.
        putio.add(PutioFile(id: 15, name: "Dune.Part.Two.2024.2160p.mkv", fileType: "VIDEO", size: 9_000_000_000,
                            createdAt: "2026-10-02T00:00:00", updatedAt: "2026-10-04T00:00:00", startFrom: 3000), to: 0)
        let index = LibraryIndex(store: LocalStore(fileURL: nil))
        index.configure(putio: putio, catalog: Self.catalog)
        await index.refresh()
        #expect(index.continueWatching.map(\.id) == [12, 10])
        // Watching the 4K copy and episode 5 moves those to the front, still one card per title.
        index.noteProgress(fileID: 15, seconds: 3100)
        index.noteProgress(fileID: 14, seconds: 200)
        #expect(index.continueWatching.map(\.id) == [14, 15])
    }

    @Test func matchingFiltersBySeasonAndEpisode() async {
        let index = makeIndex()
        await index.refresh()
        #expect(index.matching(tmdbID: 95396, season: 2, episode: 4).map(\.id) == [12])
        #expect(index.matching(tmdbID: 95396).count == 2)
        #expect(index.matching(tmdbID: 693134).map(\.id) == [10])
    }

    @Test func cachedMatchesSkipTMDB() async {
        let store = LocalStore(fileURL: nil)
        await makeIndex(store: store).refresh()
        var offline = Self.catalog
        offline.failAll = true
        let second = makeIndex(catalog: offline, store: store)
        await second.refresh()
        #expect(second.entries.first { $0.id == 10 }?.match?.tmdbID == 693134)
    }

    @Test func recordInsertsOrUpdatesEntry() async {
        let index = makeIndex()
        await index.refresh()
        let file = PutioFile(id: 99, name: "x.mkv", fileType: "VIDEO")
        await index.record(file: file, match: LibraryMatch(tmdbID: 5, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "X"))
        #expect(index.entries.first?.id == 99)
        #expect(index.matching(tmdbID: 5).count == 1)
    }

    @Test func signedOutIndexIsEmpty() async {
        let index = makeIndex()
        await index.refresh()
        index.configure(putio: nil, catalog: nil)
        #expect(index.entries.isEmpty)
    }
}
