import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// Watched videos: when a video counts as watched, how the mark travels between devices (and is undone by a rewatch),
/// and Continue Watching's Up Next cards that take a watched episode's place.
@MainActor @Suite struct WatchedTests {
    /// 2026-10-14
    let today = Date(timeIntervalSince1970: 1_791_979_200)
    let t = { (seconds: TimeInterval) in Date(timeIntervalSince1970: 1_791_900_000 + seconds) }

    // MARK: Fixtures

    /// Severance S2 E4 (12, started) and S2 E5 (15), Dune (10, started), Heat (11).
    static func tree() -> FakePutio {
        let putio = LibraryIndexTests.tree()
        putio.add(PutioFile(id: 15, name: "Severance.S02E05.1080p.mkv", fileType: "VIDEO", size: 2_000_000_000,
                            createdAt: "2026-09-03T00:00:00"), to: 2)
        return putio
    }

    func library(catalog: FakeCatalog? = nil, putio: FakePutio = WatchedTests.tree()) async -> LibraryIndex {
        let index = LibraryIndex(store: LocalStore(fileURL: nil))
        index.configure(putio: putio, catalog: catalog ?? LibraryIndexTests.catalog)
        await index.refresh()
        return index
    }

    /// Severance on TMDB: season 1 (9 episodes), season 2 (10; `aired` of them have aired by `today`).
    func severance(aired: Int = 10, seasons: Int = 2) -> FakeCatalog {
        var catalog = LibraryIndexTests.catalog
        catalog.details[95396] = TitleDetail(item: show(95396, "Severance"), imdbID: "tt11280740",
                                             seasons: (1...seasons).map { SeasonSummary(number: $0, name: "Season \($0)",
                                                                                        episodeCount: 10, posterPath: nil) })
        catalog.seasons[1] = episodes(9)
        catalog.seasons[2] = episodes(10, aired: aired)
        return catalog
    }

    func episodes(_ count: Int, aired: Int? = nil) -> [Episode] {
        (1...count).map { n in
            Episode(number: n, name: "Episode \(n) Title", overview: "", stillPath: nil,
                    airDate: n <= (aired ?? count) ? "2026-0\(min(n, 9))-01" : "2026-12-01")
        }
    }

    func watch(_ fileID: Int64, in library: LibraryIndex, at seconds: Double = 2900, of duration: Double = 3000,
               putio: FakePutio = FakePutio()) async {
        let session = PlaybackSession(fileID: fileID, resumeFrom: 0, putio: putio, library: library)
        await session.finish(seconds: seconds, duration: duration)
    }

    // MARK: When it counts as watched

    @Test func watchedInTheLastTenPercentAtMostTenMinutes() {
        // A 5-minute video: the last 10% (30 s).
        #expect(Watched.threshold(duration: 300) == 270)
        // A 22-minute episode: 132 s before the end.
        #expect(Watched.threshold(duration: 22 * 60) == 1188)
        // The Gentlemen: a 52-minute episode stopped with 3 minutes left (the credits) is watched.
        #expect(Watched.isReached(position: 49 * 60, duration: 52 * 60))
        #expect(!Watched.isReached(position: 46 * 60, duration: 52 * 60))
        // An hour: the last 6 minutes. Two hours: the last 10 minutes, not 12.
        #expect(Watched.threshold(duration: 3600) == 3240)
        #expect(Watched.threshold(duration: 7200) == 6600)
        // Very short: the credits (20 s at least) still count.
        #expect(Watched.threshold(duration: 120) == 100)
        #expect(Watched.threshold(duration: 0) == nil)
        #expect(Watched.threshold(duration: .nan) == nil)
        #expect(Watched.isReached(position: 271, duration: 300))
        #expect(!Watched.isReached(position: 269, duration: 300))
        #expect(!Watched.isReached(position: 5000, duration: 0), "length unknown: never watched by position")
    }

    @Test func watchingToTheEndMarksItAndResetsPutio() async {
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        let index = await library()
        let session = PlaybackSession(fileID: 10, resumeFrom: 0, putio: putio, library: index, store: store)
        await session.tick(seconds: 2600, duration: 3000)
        #expect(!index.isWatched(fileID: 10), "87%: not yet")
        await session.finish(seconds: 2860, duration: 3000)
        #expect(index.isWatched(fileID: 10))
        #expect(index.resumeSeconds(fileID: 10) == 0)
        #expect(putio.startFromResets == [10])
        #expect(await store.snapshot.finished.map(\.fileID) == [10])
        #expect(!index.continueWatching.contains { $0.id == 10 }, "a watched movie leaves Continue Watching")
        #expect(index.continueWatchingCards.map(\.id) == ["resume-12"])
    }

    @Test func nextEpisodeMarksItWherever() async {
        let putio = FakePutio()
        let index = await library()
        let session = PlaybackSession(fileID: 12, resumeFrom: 900, putio: putio, library: index)
        // Play Now on the Next Episode card (or its countdown) before 95%.
        await session.markWatched(seconds: 2000, duration: 3000)
        #expect(index.isWatched(fileID: 12))
        // Closing the player saves again: still watched.
        await session.finish(seconds: 2001, duration: 3000)
        #expect(index.isWatched(fileID: 12))
        #expect(putio.startFromSets.isEmpty)
    }

    // MARK: The mark, across sources

    @Test func aRewatchUnmarksItButAPeekDoesNot() async {
        let putio = FakePutio()
        let index = await library()
        await watch(10, in: index)
        #expect(index.isWatched(fileID: 10))
        // Opened again for a few seconds: still watched, and put.io isn't told.
        let peek = PlaybackSession(fileID: 10, resumeFrom: 0, putio: putio, library: index)
        await peek.finish(seconds: 12, duration: 3000)
        #expect(index.isWatched(fileID: 10))
        #expect(putio.startFromSets.isEmpty)
        // Watched again for a while: a resume again.
        let rewatch = PlaybackSession(fileID: 10, resumeFrom: 0, putio: putio, library: index)
        await rewatch.finish(seconds: 600, duration: 3000)
        #expect(!index.isWatched(fileID: 10))
        #expect(index.continueWatching.first?.id == 10)
    }

    @Test func putiosZeroAfterTheMarkKeepsItWatched() async {
        let index = await library()
        index.noteProgress(fileID: 10, seconds: 0, now: t(0), watched: true)
        index.markSent(fileID: 10, at: t(0))
        index.notePutioPositions([10: 0], readAt: t(60))
        #expect(index.isWatched(fileID: 10))
        // The put.io list of an update (its old 120 s) read before the mark changes nothing either.
        index.notePutioPositions([10: 120], readAt: t(-60))
        #expect(index.isWatched(fileID: 10))
    }

    @Test func aNewerPositionInPutioIsARewatchElsewhere() async {
        let index = await library()
        index.noteProgress(fileID: 10, seconds: 0, now: t(0), watched: true)
        index.markSent(fileID: 10, at: t(0))
        // A few seconds elsewhere: not a rewatch.
        index.notePutioPositions([10: 10], readAt: t(30))
        #expect(index.isWatched(fileID: 10))
        index.notePutioPositions([10: 900], readAt: t(60))
        #expect(!index.isWatched(fileID: 10))
        #expect(index.resumeSeconds(fileID: 10) == 900)
    }

    @Test func aMarkPutioHasNotGotYetIsNotUndoneByItsOldPosition() async {
        let putio = Self.tree()
        putio.failingSaves = 2
        let index = await library(putio: putio)
        let session = PlaybackSession(fileID: 12, resumeFrom: 900, putio: putio, library: index, retryDelay: .zero)
        await session.finish(seconds: 2950, duration: 3000)
        // put.io still says 900 (the reset didn't reach it).
        index.notePutioPositions([12: 900], readAt: Date().addingTimeInterval(5))
        #expect(index.isWatched(fileID: 12))
    }

    @Test func putioGoingToZeroMeansWatchedElsewhere() async {
        let index = await library()
        #expect(index.resumeSeconds(fileID: 12) == 900)
        index.notePutioPositions([12: 0], readAt: Date())
        #expect(index.isWatched(fileID: 12))
        // A file never started isn't "watched" by put.io's 0.
        index.notePutioPositions([11: 0], readAt: Date())
        #expect(!index.isWatched(fileID: 11))
    }

    @Test func theMarkSurvivesARelaunch() async throws {
        let cache = LibraryCache(fileURL: nil)
        let index = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        index.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await index.refresh()
        index.noteProgress(fileID: 12, seconds: 0, now: t(0), watched: true)
        for _ in 0..<200 {
            if await cache.load()?.positions?[12]?.isWatched == true { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let relaunched = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        relaunched.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await relaunched.loadCached()
        #expect(relaunched.isWatched(fileID: 12))
        // Caches from before the mark existed still load.
        let old = #"{"entries":[],"updatedAt":0,"positions":[11,{"seconds":600,"at":0,"source":"device","pending":false}]}"#
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(old.utf8))
        #expect(snapshot.positions?[11]?.isWatched == false)
    }

    // MARK: Up Next

    @Test func theNextEpisodeInTheSameSeasonIsUpNext() async throws {
        let index = await library(catalog: severance())
        await watch(12, in: index)
        // Before TMDB answers, the next file in put.io stands in.
        var card = try #require(index.continueWatchingCards.first?.upNext)
        #expect(card.label == "Up Next · S2 E5")
        #expect(card.entry?.id == 15)
        #expect(card.name == nil)
        #expect(!index.continueWatchingCards.contains { $0.resumeEntry?.id == 12 }, "the watched episode's card is gone")
        // TMDB's answer adds the name.
        index.noteUpNext(await lookup(after: 12, in: index, catalog: severance()), after: key(2, 4), now: today)
        card = try #require(index.continueWatchingCards.first?.upNext)
        #expect(card.name == "Episode 5 Title")
        #expect(card.isInPutio)
        #expect(index.watchingCard(tmdbID: 95396) == .upNext(card))
    }

    @Test func afterASeasonFinaleItsTheNextSeasonsFirst() async {
        let next = await lookup(season: 1, episode: 9, catalog: severance())
        guard case let .next(found) = next else { Issue.record("expected an episode"); return }
        #expect(found.label == "S2 E1")
    }

    @Test func theLastAiredEpisodeLeavesTheRow() async {
        let index = await library(catalog: severance(aired: 4))
        await watch(12, in: index)
        #expect(index.continueWatchingCards.first?.upNext?.episode == 5, "the file in put.io, until TMDB says")
        let found = await lookup(after: 12, in: index, catalog: severance(aired: 4))
        #expect(found == .none, "S2 E5 hasn't aired")
        index.noteUpNext(found, after: key(2, 4), now: today)
        #expect(index.continueWatchingCards.map(\.id) == ["resume-10"])
        // Asked again later: a new episode may have aired.
        #expect(index.upNextToFind(now: today).isEmpty)
        #expect(index.upNextToFind(now: today.addingTimeInterval(LibraryIndex.upNextMaxAge)) == [key(2, 4)])
    }

    @Test func theSeriesFinaleLeavesTheRow() async {
        let found = await lookup(season: 2, episode: 10, catalog: severance())
        #expect(found == .none)
    }

    @Test func notInPutioOpensTheShow() async throws {
        let index = await library(catalog: severance())
        await watch(15, in: index)
        index.noteUpNext(await lookup(after: 15, in: index, catalog: severance()), after: key(2, 5), now: today)
        let card = try #require(index.continueWatchingCards.first?.upNext)
        #expect(card.episodeLabel == "S2 E6")
        #expect(!card.isInPutio)
        #expect(card.label == "Up Next · S2 E6 · Not in put.io")
        #expect(card.titleItem.tmdbID == 95396)
    }

    @Test func withoutTMDBTheNextFileStandsIn() async {
        var offline = severance()
        offline.failAll = true
        let found = await lookup(season: 2, episode: 4, catalog: offline)
        #expect(found == .unknown)
        let index = await library(catalog: severance())
        await watch(12, in: index)
        index.noteUpNext(found, after: key(2, 4), now: today)
        #expect(index.continueWatchingCards.first?.upNext?.entry?.id == 15)
        #expect(index.upNextToFind(now: today) == [key(2, 4)], "asked again next time")
        // Not in put.io, and TMDB unreachable: nothing to offer yet.
        await watch(15, in: index)
        #expect(index.continueWatchingCards.map(\.id) == ["resume-10"])
    }

    @Test func upNextIsOrderedByWhenTheEpisodeWasWatchedWithResumeCards() async {
        let index = await library()
        index.noteProgress(fileID: 12, seconds: 0, now: t(100), watched: true)
        index.noteProgress(fileID: 11, seconds: 600, now: t(200))
        index.noteProgress(fileID: 10, seconds: 300, now: t(50))
        #expect(index.continueWatchingCards.map(\.id) == ["resume-11", "upnext-95396", "resume-10"])
        #expect(index.continueWatching.map(\.id) == [11, 10])
    }

    /// Remove from Continue Watching (touch and hold): the card stays gone until that title is played again.
    @Test func removedCardsStayGoneUntilPlayedAgain() async throws {
        let index = await library()
        index.noteProgress(fileID: 12, seconds: 0, now: t(100), watched: true)
        index.noteProgress(fileID: 11, seconds: 600, now: t(200))
        index.noteProgress(fileID: 10, seconds: 300, now: t(50))
        let heat = try #require(index.continueWatchingCards.first)
        index.removeFromContinueWatching(heat)
        index.removeFromContinueWatching(try #require(index.continueWatchingCards.first { $0.upNext != nil }))
        #expect(index.continueWatchingCards.map(\.id) == ["resume-10"])
        #expect(index.continueWatching.map(\.id) == [10])
        // Played again: back, and the removal is forgotten.
        index.noteProgress(fileID: 11, seconds: 900, now: t(300))
        #expect(index.continueWatchingCards.map(\.id) == ["resume-11", "resume-10"])
        // The next episode watched: the show is back with what follows it.
        index.noteProgress(fileID: 15, seconds: 400, now: t(400))
        #expect(index.continueWatchingCards.map(\.id) == ["resume-15", "resume-11", "resume-10"])
    }

    @Test func removedCardsSurviveARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let index = LibraryIndex(store: LocalStore(fileURL: nil), cache: LibraryCache(fileURL: file))
        index.configure(putio: Self.tree(), catalog: LibraryIndexTests.catalog)
        await index.refresh()
        index.noteProgress(fileID: 11, seconds: 600, now: t(200))
        index.removeFromContinueWatching(try #require(index.continueWatchingCards.first { $0.id == "resume-11" }))
        try? await Task.sleep(for: .milliseconds(150))
        let next = LibraryIndex(store: LocalStore(fileURL: nil), cache: LibraryCache(fileURL: file))
        next.configure(putio: Self.tree(), catalog: LibraryIndexTests.catalog)
        await next.loadCached()
        #expect(!next.continueWatchingCards.contains { $0.id == "resume-11" })
    }

    @Test func oneCardPerShowByWhatWasWatchedLast() async {
        let index = await library()
        // E5 started, then E4 finished: Up Next (E5) replaces both.
        index.noteProgress(fileID: 15, seconds: 400, now: t(10))
        index.noteProgress(fileID: 12, seconds: 0, now: t(20), watched: true)
        #expect(index.continueWatchingCards.filter { $0.tmdbID == 95396 }.map(\.id) == ["upnext-95396"])
        // Watching E5 further: back to resuming it.
        index.noteProgress(fileID: 15, seconds: 900, now: t(30))
        #expect(index.continueWatchingCards.filter { $0.tmdbID == 95396 }.map(\.id) == ["resume-15"])
    }

    @Test func findUpNextAsksTMDBOncePerWatchedEpisode() async {
        let putio = Self.tree()
        let catalog = severance()
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in catalog }, makeProvider: { _, _ in nil })
        let app = AppModel(tokens: InMemoryTokenStore([.putio: "t", .tmdb: "t"]), defaults: testDefaults(),
                           store: LocalStore(fileURL: nil), factory: factory)
        await app.library.refresh()
        app.library.noteProgress(fileID: 12, seconds: 0, watched: true)
        #expect(app.library.upNextToFind() == [key(2, 4)])
        await app.findUpNext()
        #expect(app.library.upNextToFind().isEmpty)
        #expect(app.library.continueWatchingCards.first?.upNext?.name == "Episode 5 Title")
    }

    @Test func theShowsPageOpensOnTheSeasonUpNext() async {
        let index = await library(catalog: severance())
        index.noteProgress(fileID: 15, seconds: 0, watched: true)
        index.noteUpNext(.next(NextUp(showTitle: "Severance", season: 3, episode: 1, name: "", overview: "", stillPath: nil,
                                      entry: nil, query: nil,
                                      target: TransferTarget(tmdbID: 95396, kind: .tv, title: "Severance", posterPath: nil,
                                                             backdropPath: nil, season: 3, episode: 1))),
                         after: key(2, 5))
        let model = TitleModel(item: show(95396, "Severance"), catalog: severance(seasons: 3), library: index,
                               transfers: TransferMonitor(store: LocalStore(fileURL: nil)))
        await model.load()
        #expect(model.selectedSeason == 3)
        let focused = TitleModel(item: show(95396, "Severance"), catalog: severance(seasons: 3), library: index,
                                 transfers: TransferMonitor(store: LocalStore(fileURL: nil)), focus: key(1, 2))
        await focused.load()
        #expect(focused.selectedSeason == 1)
    }

    // MARK: Other devices

    @Test func upNextReachesTheOtherDevicesThroughTheLog() async {
        let putio = Self.tree()
        let keychain = InMemoryWatchLogStore()
        let ipad = await CrossDeviceResumeTests().cachedDevice(putio, keychain: keychain, name: "iPad")
        let tv = await CrossDeviceResumeTests().cachedDevice(putio, keychain: keychain, name: "Apple TV")
        await ipad.syncWatchLog()
        let entry = ipad.library.entries.first { $0.id == 12 }
        let session = PlaybackSession(fileID: 12, resumeFrom: 900, putio: putio, library: ipad.library, entry: entry,
                                      watchLog: ipad.watchLog)
        await session.finish(seconds: 2950, duration: 3000)
        #expect(ipad.watchLog.entries.first?.isWatched == true)

        await tv.refreshContinueWatching()
        #expect(tv.library.isWatched(fileID: 12))
        #expect(tv.library.continueWatchingCards.first?.id == "upnext-95396")
        #expect(tv.library.continueWatchingCards.first?.upNext?.episodeLabel == "S2 E5")

        // Watched again on the TV for a while: the iPad sees a resume again.
        let rewatch = PlaybackSession(fileID: 12, resumeFrom: 0, putio: putio, library: tv.library, entry: entry,
                                      watchLog: tv.watchLog)
        await rewatch.finish(seconds: 700, duration: 3000)
        await ipad.refreshContinueWatching()
        #expect(!ipad.library.isWatched(fileID: 12))
        #expect(ipad.library.continueWatchingCards.first?.id == "resume-12")
    }

    @Test func aWatchedFileTheOtherDeviceDoesNotHaveStillGivesUpNext() async {
        let putio = Self.tree()
        let library = await library(putio: putio)
        // S2 E3, played from Files on another device (not in this library), watched to the end.
        let log = [WatchLogEntry(fileID: 300, name: "Severance.S02E03.mkv", tmdbID: 95396, kind: .tv, season: 2, episode: 3,
                                 title: "Severance", seconds: 0, duration: 3000, at: Date(), watched: true)]
        library.noteOtherDevices(log)
        #expect(library.continueWatchingCards.first?.upNext?.entry?.id == 12, "S2 E4, in put.io")
        #expect(library.positionCandidates(log: log).first == 300, "asked about: a rewatch elsewhere brings it back")
    }

    // MARK: Helpers

    func key(_ season: Int, _ episode: Int) -> EpisodeKey { EpisodeKey(tmdbID: 95396, season: season, episode: episode) }

    func lookup(season: Int, episode: Int, catalog: FakeCatalog) async -> NextUpLookup {
        await NextUpFinder.lookup(tmdbID: 95396, season: season, episode: episode, catalog: catalog,
                                  library: LibraryIndex(store: LocalStore(fileURL: nil)), today: today)
    }

    func lookup(after fileID: Int64, in library: LibraryIndex, catalog: FakeCatalog) async -> NextUpLookup {
        let match = library.entries.first { $0.id == fileID }?.match
        return await NextUpFinder.lookup(tmdbID: 95396, season: match?.season ?? 0, episode: match?.episode ?? 0,
                                         catalog: catalog, library: library, today: today)
    }
}
