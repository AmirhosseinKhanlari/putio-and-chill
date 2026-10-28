import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// Resuming on another device: put.io's start-from is the shared position, read when the app comes back and before
/// playing; positions carry when they were true and the newest wins; an update never drops one.
@MainActor @Suite struct CrossDeviceResumeTests {
    /// An app on one device, with its own library cache, talking to the shared (fake) put.io and iCloud Keychain.
    func device(_ putio: FakePutio, cache: LibraryCache = LibraryCache(fileURL: nil),
                keychain: (any WatchLogStore)? = nil, name: String = "iPad") -> AppModel {
        let catalog = LibraryIndexTests.catalog
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in catalog }, makeProvider: { _, _ in nil })
        return AppModel(tokens: InMemoryTokenStore([.putio: "t", .tmdb: "t"]), defaults: testDefaults(),
                        store: LocalStore(fileURL: nil), factory: factory, libraryCache: cache,
                        watchLogStore: keychain, deviceName: name)
    }

    /// A device whose library was updated earlier and is shown from its cache now (no update due).
    func cachedDevice(_ putio: FakePutio, keychain: (any WatchLogStore)? = nil, name: String = "Apple TV") async -> AppModel {
        let cache = LibraryCache(fileURL: nil)
        let earlier = device(putio, cache: cache)
        await earlier.library.refresh()
        let app = device(putio, cache: cache, keychain: keychain, name: name)
        await app.library.loadCached()
        return app
    }

    // MARK: The bug

    @Test func anotherDevicesPositionShowsWhenTheAppComesBackWithoutAnUpdate() async {
        let putio = LibraryIndexTests.tree()
        let tv = await cachedDevice(putio)
        #expect(!tv.library.continueWatching.contains { $0.id == 11 })

        // Heat is watched to 42 minutes on the iPad, which saves it in put.io.
        putio.setPosition(2520, fileID: 11)
        let listsBefore = putio.listCalls
        await tv.refreshContinueWatching()

        #expect(putio.listCalls == listsBefore, "no library update")
        #expect(tv.library.resumeSeconds(fileID: 11) == 2520)
        #expect(tv.library.continueWatching.first?.id == 11, "just watched elsewhere: first")
    }

    @Test func anUpdateWhoseListHasNoPositionKeepsOneSavedInAnEarlierSession() async {
        let cache = LibraryCache(fileURL: nil)
        let putio = LibraryIndexTests.tree()
        let earlier = device(putio, cache: cache)
        await earlier.library.refresh()
        // Episode 5 (no start_from in put.io's list) played on this device last time, and put.io got it.
        let session = PlaybackSession(fileID: 14, resumeFrom: 0, putio: putio, library: earlier.library)
        await session.finish(seconds: 777, duration: 3000)
        await waitForSave(cache) { $0.positions?[14]?.pending == false }

        let relaunched = device(putio, cache: cache)
        await relaunched.library.loadCached()
        await relaunched.library.refresh()
        #expect(relaunched.library.resumeSeconds(fileID: 14) == 777)
        #expect(relaunched.library.continueWatching.contains { $0.id == 14 })
    }

    @Test func playingAsksPutioForTheNewestPosition() async {
        let putio = LibraryIndexTests.tree()
        let tv = await cachedDevice(putio)
        #expect(tv.library.resumeSeconds(fileID: 10) == 120)
        putio.setPosition(3300, fileID: 10)
        #expect(await tv.library.freshResumeSeconds(fileID: 10) == 3300)
    }

    @Test func playingWithoutPutioUsesWhatsKnownHere() async {
        let putio = LibraryIndexTests.tree()
        let tv = await cachedDevice(putio)
        putio.setPosition(3300, fileID: 10)
        putio.startFromDelay = .seconds(5)
        let started = ContinuousClock.now
        #expect(await tv.library.freshResumeSeconds(fileID: 10, timeout: .milliseconds(100)) == 120)
        #expect(ContinuousClock.now - started < .seconds(2), "a slow put.io doesn't hold up playback")
    }

    @Test func finishedOnAnotherDeviceLeavesContinueWatching() async {
        let putio = LibraryIndexTests.tree()
        let tv = await cachedDevice(putio)
        #expect(tv.library.continueWatching.map(\.id) == [12, 10])
        // Severance S02E04 watched to the end on the iPad: put.io's position is reset.
        putio.setPosition(0, fileID: 12)
        await tv.refreshContinueWatching()
        #expect(tv.library.continueWatching.map(\.id) == [10])
    }

    @Test func aPositionPutioHasNotGotIsNotReplacedByPutiosOlderOne() async {
        let putio = LibraryIndexTests.tree()
        let tv = await cachedDevice(putio)
        putio.failingSaves = 2
        let session = PlaybackSession(fileID: 11, resumeFrom: 0, putio: putio, library: tv.library, retryDelay: .zero)
        await session.finish(seconds: 1500, duration: 6000)
        #expect(tv.library.pendingPositions.map(\.fileID) == [11])

        // put.io still says 0: the unsent position stays, and goes to put.io with the next check.
        await tv.refreshContinueWatching()
        #expect(tv.library.resumeSeconds(fileID: 11) == 1500)
        #expect(putio.startFromSets.last?.fileID == 11)
        #expect(putio.startFromSets.last?.seconds == 1500)
        #expect(tv.library.pendingPositions.isEmpty)
    }

    // MARK: Newest wins

    @Test func newestWins() {
        let t = { (seconds: TimeInterval) in Date(timeIntervalSince1970: 1_000_000 + seconds) }
        let sentHere = WatchProgress(seconds: 600, at: t(0), source: .device, watchedAt: t(0))
        let unsentHere = WatchProgress(seconds: 600, at: t(0), source: .device, watchedAt: t(0), pending: true)

        // put.io read after a save it got: put.io's value (moved on another device since).
        let later = WatchProgress(seconds: 1800, at: t(60), source: .putio, watchedAt: t(60))
        #expect(WatchProgress.merged(sentHere, later).seconds == 1800)
        #expect(WatchProgress.merged(sentHere, later).watchedAt == t(60))
        // ... but never over a save put.io hasn't got, nor with a read that began before the save.
        #expect(WatchProgress.merged(unsentHere, later) == unsentHere)
        let earlier = WatchProgress(seconds: 1800, at: t(-60), source: .putio, watchedAt: t(-60))
        #expect(WatchProgress.merged(sentHere, earlier) == sentHere)
        // The same value just confirms put.io has it.
        let confirmed = WatchProgress.merged(unsentHere, WatchProgress(seconds: 600, at: t(30), source: .putio))
        #expect(!confirmed.pending)
        #expect(confirmed.watchedAt == t(0), "confirming isn't watching")

        // Another device: newer wins, older doesn't.
        let otherLater = WatchProgress(seconds: 2400, at: t(120), source: .otherDevice, watchedAt: t(120))
        let otherEarlier = WatchProgress(seconds: 100, at: t(-120), source: .otherDevice, watchedAt: t(-120))
        #expect(WatchProgress.merged(unsentHere, otherLater).seconds == 2400)
        #expect(!WatchProgress.merged(unsentHere, otherLater).pending, "superseded: not sent over the newer one")
        #expect(WatchProgress.merged(sentHere, otherEarlier) == sentHere)

        // A save here always wins.
        let now = WatchProgress(seconds: 50, at: t(200), source: .device, watchedAt: t(200), pending: true)
        #expect(WatchProgress.merged(otherLater, now) == now)
    }

    @Test func aSaveDuringACheckIsNotUndoneByIt() async {
        let putio = LibraryIndexTests.tree()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: putio, catalog: LibraryIndexTests.catalog)
        await library.refresh()
        let readBegan = Date()
        library.noteProgress(fileID: 10, seconds: 700, now: readBegan.addingTimeInterval(1))
        library.markSent(fileID: 10, at: readBegan.addingTimeInterval(1))
        library.notePutioPositions([10: 120], readAt: readBegan)
        #expect(library.resumeSeconds(fileID: 10) == 700)
    }

    // MARK: Retries

    @Test func aFailedSaveIsRetriedOnce() async {
        let putio = FakePutio()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        putio.failingSaves = 1
        let session = PlaybackSession(fileID: 5, resumeFrom: 0, putio: putio, library: library, retryDelay: .zero)
        await session.finish(seconds: 400, duration: 1000)
        #expect(putio.startFromSets.map(\.seconds) == [400])
        #expect(library.pendingPositions.isEmpty)
    }

    @Test func anUnsentSaveGoesWithTheNextOne() async {
        let putio = FakePutio()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: putio, catalog: nil)
        putio.failingSaves = 2
        let first = PlaybackSession(fileID: 5, resumeFrom: 0, putio: putio, library: library, retryDelay: .zero)
        await first.finish(seconds: 400, duration: 1000)
        #expect(library.pendingPositions.map(\.seconds) == [400])
        // Another video saves fine: the one put.io missed is sent too.
        let second = PlaybackSession(fileID: 6, resumeFrom: 0, putio: putio, library: library, retryDelay: .zero)
        await second.finish(seconds: 90, duration: 1000)
        #expect(putio.startFromSets.map(\.fileID).sorted() == [5, 6])
        #expect(library.pendingPositions.isEmpty)
    }

    // MARK: Other Apple devices (iCloud Keychain)

    @Test func whatTheIPadWatchedShowsFirstOnTheTV() async {
        let putio = LibraryIndexTests.tree()
        let keychain = InMemoryWatchLogStore()
        let tv = await cachedDevice(putio, keychain: keychain, name: "Apple TV")
        let ipad = await cachedDevice(putio, keychain: keychain, name: "iPad")
        await ipad.syncWatchLog()
        // Arrival, played from Files on the iPad: the TV's library doesn't have it.
        let session = PlaybackSession(fileID: 99, resumeFrom: 0, putio: putio, library: ipad.library,
                                      entry: ContinueWatchingTests.outside, watchLog: ipad.watchLog)
        await session.finish(seconds: 1800, duration: 6960)
        #expect(ipad.watchLog.entries.first?.device == "iPad")

        await tv.refreshContinueWatching()
        let first = tv.library.continueWatching.first
        #expect(first?.id == 99)
        #expect(first?.match?.title == "Arrival", "shown from what the iPad knew about it")
        #expect(tv.library.remainingSeconds(for: first!) == 5160)
    }

    /// A file the iPad played that was deleted from put.io since: the TV learns it's gone (404) and drops its card,
    /// and remembers that across a relaunch, so the iPad's list can't bring it back at every start.
    @Test func aFileDeletedOnPutioStaysGoneAfterARelaunch() async {
        let putio = LibraryIndexTests.tree()
        let keychain = InMemoryWatchLogStore()
        let ipad = await cachedDevice(putio, keychain: keychain, name: "iPad")
        await ipad.syncWatchLog()
        let session = PlaybackSession(fileID: 99, resumeFrom: 0, putio: putio, library: ipad.library,
                                      entry: ContinueWatchingTests.outside, watchLog: ipad.watchLog)
        await session.finish(seconds: 1800, duration: 6960)
        putio.missingFiles = [99]

        let cache = LibraryCache(fileURL: nil)
        let tv = device(putio, cache: cache, keychain: keychain, name: "Apple TV")
        await tv.library.refresh()
        await tv.refreshContinueWatching()
        #expect(!tv.library.entries.contains { $0.id == 99 }, "put.io says it's gone")
        for _ in 0..<200 where await cache.load()?.goneFiles == nil { try? await Task.sleep(for: .milliseconds(10)) }

        let relaunched = device(putio, cache: cache, keychain: keychain, name: "Apple TV")
        await relaunched.library.loadCached()
        // The iPad's list still names it: it doesn't come back as a card while put.io is asked about it again.
        await relaunched.syncWatchLog()
        #expect(!relaunched.library.entries.contains { $0.id == 99 })
        await relaunched.refreshContinueWatching()
        #expect(!relaunched.library.continueWatching.contains { $0.id == 99 })
    }

    @Test func theLogIsPerPutioAccount() async {
        let keychain = InMemoryWatchLogStore()
        let mine = FakePutio()
        mine.accountUserID = 1
        let theirs = FakePutio()
        theirs.accountUserID = 2
        let me = device(mine, keychain: keychain)
        let them = device(theirs, keychain: keychain)
        await me.syncWatchLog()
        me.watchLog.record(WatchLogEntry(fileID: 7, seconds: 300, at: Date()))
        await them.syncWatchLog()
        #expect(them.watchLog.entries.isEmpty)
        #expect(me.watchLog.account == "watchlog.1")
        #expect(them.watchLog.account == "watchlog.2")
    }

    @Test func demoModeNeitherReadsNorWritesTheLog() async {
        let putio = LibraryIndexTests.tree()
        let app = device(putio, keychain: nil)
        await app.library.refresh()
        let session = PlaybackSession(fileID: 10, resumeFrom: 0, putio: putio, library: app.library, watchLog: app.watchLog)
        await session.finish(seconds: 500, duration: 6000)
        await app.syncWatchLog()
        #expect(!app.watchLog.isEnabled)
        #expect(app.watchLog.entries.isEmpty)
        #expect(putio.accountCalls == 0)
    }

    @Test func logKeepsTheNewestPlayOfEachFileNewestFirstAndCapped() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = (0..<30).map { WatchLogEntry(fileID: Int64($0), seconds: 100, at: base.addingTimeInterval(Double($0))) }
        let b = (20..<50).map { WatchLogEntry(fileID: Int64($0), seconds: 200, at: base.addingTimeInterval(Double($0) + 0.5)) }
        let merged = WatchLog.merged(a, b)
        #expect(merged.count == WatchLog.limit)
        #expect(merged.first?.fileID == 49)
        #expect(merged.map(\.at) == merged.map(\.at).sorted(by: >))
        #expect(merged.first { $0.fileID == 25 }?.seconds == 200, "the newer play of a file wins")
        #expect(Set(merged.map(\.fileID)).count == merged.count, "one per file")
    }

    @Test func playsBeforeTheAccountIsKnownAreWrittenOnceItIs() {
        let keychain = InMemoryWatchLogStore()
        let log = WatchLogSync(store: keychain, deviceName: "iPhone")
        log.record(WatchLogEntry(fileID: 3, seconds: 90, at: Date()))
        log.use(account: "watchlog.1")
        #expect(WatchLog.decode(keychain.read(account: "watchlog.1")).map(\.fileID) == [3])
        // Another account signing in starts from its own list.
        log.use(account: "watchlog.2")
        #expect(log.entries.isEmpty)
    }

    @Test func otherDevicesWritesAreMergedNotOverwritten() {
        let keychain = InMemoryWatchLogStore()
        let ipad = WatchLogSync(store: keychain, deviceName: "iPad")
        let tv = WatchLogSync(store: keychain, deviceName: "Apple TV")
        ipad.use(account: "watchlog.1")
        tv.use(account: "watchlog.1")
        ipad.record(WatchLogEntry(fileID: 1, seconds: 100, at: Date(timeIntervalSince1970: 10)))
        tv.record(WatchLogEntry(fileID: 2, seconds: 200, at: Date(timeIntervalSince1970: 20)))
        #expect(ipad.pull().map(\.fileID) == [2, 1])
        #expect(WatchLog.decode(keychain.read(account: "watchlog.1")).map(\.device) == ["Apple TV", "iPad"])
    }

    // MARK: Which files are checked

    @Test func candidatesAreNewestFirstAndCapped() async {
        let putio = LibraryIndexTests.tree()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: putio, catalog: LibraryIndexTests.catalog)
        await library.refresh()
        library.noteProgress(fileID: 11, seconds: 300)
        let log = [WatchLogEntry(fileID: 500, seconds: 600, at: Date()), WatchLogEntry(fileID: 501, seconds: 0, at: Date())]
        let ids = library.positionCandidates(log: log)
        #expect(ids.first == 500, "played elsewhere lately")
        #expect(!ids.contains(501), "finished elsewhere: nothing to ask")
        #expect(Array(ids.dropFirst().prefix(3)) == [11, 12, 10], "then started here, most recently watched first")
        #expect(Set(ids) == [500, 11, 12, 10, 14])
        #expect(library.positionCandidates(log: log, limit: 2, recentSlots: 0).count == 2)
        // Plenty started: the most recently changed videos still get their slots.
        #expect(library.positionCandidates(log: log, limit: 3, recentSlots: 1) == [500, 11, 12])
        let crowded = (0..<40).map { WatchLogEntry(fileID: Int64(1000 + $0), seconds: 600, at: Date()) }
        let ids2 = library.positionCandidates(log: crowded)
        #expect(ids2.count == 24, "20 played elsewhere, then the library's 4 videos by put.io's change date")
        #expect(ids2.contains(14), "a recently added video is checked even when lots are started")
    }

    @Test func aFileDeletedOnPutioIsNotBroughtBack() async {
        let putio = LibraryIndexTests.tree()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: putio, catalog: LibraryIndexTests.catalog)
        await library.refresh()
        let gone = WatchLogEntry(fileID: 98, name: "Gone.mkv", seconds: 600, at: Date())
        library.noteOtherDevices([gone])
        #expect(library.entries.contains { $0.id == 98 })
        putio.missingFiles = [98]
        await library.checkPositions([98])
        #expect(!library.entries.contains { $0.id == 98 })
        library.noteOtherDevices([gone])
        #expect(!library.entries.contains { $0.id == 98 })
    }

    @Test func olderCachesKeepTheirPositions() throws {
        let json = #"{"entries":[],"updatedAt":0,"progress":[11,777],"watched":[11,100]}"#
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(json.utf8))
        let record = try #require(snapshot.allPositions[11])
        #expect(record.seconds == 777)
        #expect(!record.pending, "already sent by that build: put.io's newer value may replace it")
        #expect(record.watchedAt == Date(timeIntervalSinceReferenceDate: 100))
    }

    private func waitForSave(_ cache: LibraryCache, until done: (LibrarySnapshot) -> Bool) async {
        for _ in 0..<200 {
            if let snapshot = await cache.load(), done(snapshot) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
