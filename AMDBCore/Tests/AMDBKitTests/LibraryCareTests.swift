import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct LibraryCareTests {
    let day: TimeInterval = 86_400

    @Test func finishingAMovieIsRecorded() async {
        let store = LocalStore(fileURL: nil)
        let session = PlaybackSession(fileID: 7, resumeFrom: 0, putio: FakePutio(), library: nil, store: store)
        await session.finish(seconds: 960, duration: 1000)
        #expect(await store.snapshot.finished.map(\.fileID) == [7])
        let midway = PlaybackSession(fileID: 8, resumeFrom: 0, putio: FakePutio(), library: nil, store: store)
        await midway.finish(seconds: 100, duration: 1000)
        #expect(await store.snapshot.finished.map(\.fileID) == [7])
    }

    /// A movie finished weeks ago that's being watched again isn't finished any more: auto-clean must not delete it
    /// under the user. Finishing it again puts it back on the list, dated now.
    @Test func rewatchingAFinishedMovieTakesItOffTheCleanList() async {
        let store = LocalStore(fileURL: nil)
        let longAgo = Date().addingTimeInterval(-35 * day)
        await store.update { $0.finished = [FinishedFile(fileID: 7, at: longAgo), FinishedFile(fileID: 8, at: longAgo)] }
        let session = PlaybackSession(fileID: 7, resumeFrom: 0, putio: FakePutio(), library: nil, store: store)
        await session.tick(seconds: 2400, duration: 7200)
        #expect(await store.snapshot.finished.map(\.fileID) == [8])
        await session.finish(seconds: 7100, duration: 7200)
        let finished = await store.snapshot.finished
        #expect(finished.map(\.fileID) == [8, 7])
        #expect(finished.last.map { $0.at > longAgo } == true)
    }

    @Test func autoCleanPicksOnlyMoviesFinishedLongEnoughAgo() {
        let now = Date(timeIntervalSince1970: 100 * day)
        func entry(_ id: Int64, _ kind: MediaKind?) -> LibraryEntry {
            LibraryEntry(file: PutioFile(id: id, name: "f\(id).mkv", fileType: "VIDEO"),
                         match: kind.map { LibraryMatch(tmdbID: Int(id), mediaType: $0, season: nil, episode: nil, confidence: 1) },
                         folderName: nil)
        }
        let entries = [entry(1, .movie), entry(2, .movie), entry(3, .tv), entry(4, nil), entry(5, .movie)]
        let finished = [FinishedFile(fileID: 1, at: now.addingTimeInterval(-40 * day)),
                        FinishedFile(fileID: 2, at: now.addingTimeInterval(-5 * day)),
                        FinishedFile(fileID: 3, at: now.addingTimeInterval(-90 * day)),
                        FinishedFile(fileID: 4, at: now.addingTimeInterval(-90 * day))]
        let due = AutoCleaner.candidates(entries: entries, finished: finished, olderThanDays: 30, now: now)
        #expect(due.map(\.id) == [1])
        #expect(AutoCleaner.candidates(entries: entries, finished: finished, olderThanDays: nil, now: now).isEmpty)
    }

    @Test func deletingRemovesFromPutioLibraryAndRecords() async throws {
        let store = LocalStore(fileURL: nil)
        let putio = FakePutio()
        putio.add(PutioFile(id: 10, name: "Dune.2021.mkv", fileType: "VIDEO"), to: 0)
        let library = LibraryIndex(store: store)
        library.configure(putio: putio, catalog: FakeCatalog())
        await library.refresh()
        await store.update { $0.finished = [FinishedFile(fileID: 10, at: Date())] }
        try await library.delete([library.entries[0]])
        #expect(library.entries.isEmpty)
        #expect(putio.deleted == [10])
        #expect(await store.snapshot.finished.isEmpty)
    }

    @Test func downloadRecordsPersistAndUpdate() async {
        let store = LocalStore(fileURL: nil)
        let downloads = DownloadsIndex(store: store)
        await downloads.load()
        let record = DownloadRecord(fileID: 3, title: "Dune", posterPath: "/d.jpg", tmdbID: 438631, kind: .movie,
                                    season: nil, episode: nil, state: .downloading(progress: 0))
        await downloads.upsert(record)
        await downloads.update(fileID: 3) { $0.state = .downloading(progress: 0.5) }
        #expect(downloads.record(fileID: 3)?.state == .downloading(progress: 0.5))
        await downloads.update(fileID: 3) { $0.state = .done(relativePath: "Library/AMDB/3.movpkg") }
        let reloaded = DownloadsIndex(store: store)
        await reloaded.load()
        #expect(reloaded.record(fileID: 3)?.state == .done(relativePath: "Library/AMDB/3.movpkg"))
        await reloaded.remove(fileID: 3)
        #expect(reloaded.records.isEmpty)
    }

    @Test func lateProgressNeverUndoesAFinishedDownload() async {
        let downloads = DownloadsIndex(store: LocalStore(fileURL: nil))
        await downloads.upsert(DownloadRecord(fileID: 7, title: "Dune", posterPath: nil, tmdbID: 1, kind: .movie,
                                              season: nil, episode: nil, state: .queued))
        await downloads.progress(fileID: 7, 0.5)
        #expect(downloads.record(fileID: 7)?.state == .downloading(progress: 0.5))
        await downloads.update(fileID: 7) { $0.state = .done(relativePath: "Library/x.movpkg") }
        await downloads.progress(fileID: 7, 0.99)
        #expect(downloads.record(fileID: 7)?.state == .done(relativePath: "Library/x.movpkg"))
        #expect(downloads.finished.map(\.fileID) == [7])
    }
}

@Suite struct SeasonDownloadStatusTests {
    @Test func oneOfTenDownloadedIsNotTheWholeSeason() {
        #expect(SeasonDownloadStatus.of(total: 10, inPutio: 1, downloaded: 1, active: 0) == .partial(downloaded: 1, total: 10))
    }

    @Test func everyEpisodeOnTheDeviceIsTheSeason() {
        #expect(SeasonDownloadStatus.of(total: 8, inPutio: 8, downloaded: 8, active: 0) == .seasonDownloaded)
    }

    @Test func offersWhatsInPutioButNotOnTheDevice() {
        #expect(SeasonDownloadStatus.of(total: 10, inPutio: 4, downloaded: 1, active: 0) == .download(count: 3, wholeSeason: false))
        #expect(SeasonDownloadStatus.of(total: 8, inPutio: 8, downloaded: 0, active: 0) == .download(count: 8, wholeSeason: true))
    }

    @Test func showsDownloadsInProgress() {
        #expect(SeasonDownloadStatus.of(total: 10, inPutio: 3, downloaded: 1, active: 2) == .downloading(count: 2))
    }
}
