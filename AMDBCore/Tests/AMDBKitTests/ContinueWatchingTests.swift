import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// Continue Watching right after playing: files the library didn't have yet, the order after watching, and the order
/// after a relaunch.
@MainActor @Suite struct ContinueWatchingTests {
    /// A file played from Files (not in the library yet, e.g. it arrived after the last update).
    static let outside = LibraryEntry(file: PutioFile(id: 99, name: "Arrival.2016.1080p.mkv", fileType: "VIDEO",
                                                      createdAt: "2026-09-01T00:00:00"),
                                      match: LibraryMatch(tmdbID: 329865, mediaType: .movie, season: nil, episode: nil,
                                                          confidence: 1, title: "Arrival"),
                                      folderName: nil)

    func refreshedIndex(cache: LibraryCache = LibraryCache(fileURL: nil)) async -> LibraryIndex {
        let index = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        index.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await index.refresh()
        return index
    }

    @Test func playedFileNotInTheLibraryShowsAtOnce() async {
        let index = await refreshedIndex()
        let putio = FakePutio()
        let session = PlaybackSession(fileID: 99, resumeFrom: 0, putio: putio, library: index, entry: Self.outside)
        await session.finish(seconds: 1800, duration: 6960)
        #expect(index.continueWatching.first?.id == 99)
        #expect(index.resumeSeconds(for: Self.outside) == 1800)
        #expect(index.remainingSeconds(for: Self.outside) == 5160)
        // Once in the library, playing it again doesn't add it twice.
        index.notePlayed(Self.outside)
        #expect(index.entries.filter { $0.id == 99 }.count == 1)
    }

    @Test func aFewSecondsDoNotAddIt() async {
        let index = await refreshedIndex()
        let session = PlaybackSession(fileID: 99, resumeFrom: 0, putio: FakePutio(), library: index, entry: Self.outside)
        await session.finish(seconds: 12, duration: 6960)
        #expect(!index.entries.contains { $0.id == 99 })
    }

    @Test func theNextUpdateKeepsItOnlyIfPutioHasIt() async {
        let putio = LibraryIndexTests.tree()
        let index = LibraryIndex(store: LocalStore(fileURL: nil))
        index.configure(putio: putio, catalog: LibraryIndexTests.catalog)
        await index.refresh()
        index.notePlayed(Self.outside)
        index.noteProgress(fileID: 99, seconds: 600)
        // put.io has it now: the update keeps one entry, with this session's position.
        putio.add(Self.outside.file, to: 0)
        await index.refresh()
        #expect(index.entries.filter { $0.id == 99 }.count == 1)
        #expect(index.continueWatching.first?.id == 99)

        // Played, then deleted on put.io: the next update drops it.
        let gone = LibraryEntry(file: PutioFile(id: 98, name: "Gone.mkv", fileType: "VIDEO"), match: nil, folderName: nil)
        index.notePlayed(gone)
        index.noteProgress(fileID: 98, seconds: 600)
        #expect(index.continueWatching.first?.id == 98)
        await index.refresh()
        #expect(!index.entries.contains { $0.id == 98 })
    }

    @Test func watchingMovesATitleToTheFront() async {
        let index = await refreshedIndex()
        #expect(index.continueWatching.map(\.id) == [12, 10])
        index.noteProgress(fileID: 10, seconds: 300)
        #expect(index.continueWatching.map(\.id) == [10, 12])
        index.noteProgress(fileID: 12, seconds: 950)
        #expect(index.continueWatching.map(\.id) == [12, 10])
    }

    @Test func orderSurvivesARelaunch() async {
        let cache = LibraryCache(fileURL: nil)
        let index = await refreshedIndex(cache: cache)
        // put.io's dates alone put Severance (12) first; Dune (10) was watched last on this device.
        index.noteProgress(fileID: 12, seconds: 950, now: Date(timeIntervalSince1970: 1_000))
        index.noteProgress(fileID: 10, seconds: 300, now: Date(timeIntervalSince1970: 2_000))
        await waitForSave(cache) { $0.watched?.count == 2 }

        let relaunched = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        relaunched.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await relaunched.loadCached()
        #expect(relaunched.continueWatching.map(\.id) == [10, 12])
    }

    @Test func seekingBackSavesWithoutWaitingToPassTheOldPoint() async {
        let putio = FakePutio()
        let session = PlaybackSession(fileID: 5, resumeFrom: 2000, putio: putio, library: nil)
        await session.tick(seconds: 2005, duration: 6000)
        await session.tick(seconds: 600, duration: 6000)
        #expect(putio.startFromSets.map(\.seconds) == [600])
    }

    /// The index saves its cache in the background after noting progress.
    private func waitForSave(_ cache: LibraryCache, until done: (LibrarySnapshot) -> Bool) async {
        for _ in 0..<200 {
            if let snapshot = await cache.load(), done(snapshot) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
