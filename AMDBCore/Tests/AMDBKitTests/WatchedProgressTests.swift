import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// The "how much is watched" bar under cards: the player's real length, else TMDB's runtime.
@MainActor @Suite struct WatchedProgressTests {
    @Test func playerLengthWinsOverTheEstimate() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let library = LibraryIndex(store: LocalStore(fileURL: nil), cache: LibraryCache(fileURL: file))
        library.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await library.refresh()
        let entry = library.entries.first { $0.id == 11 }!

        // Not started: no bar.
        #expect(library.watchedFraction(for: entry, estimatedLength: 3360) == nil)

        let session = PlaybackSession(fileID: 11, resumeFrom: 0, putio: FakePutio(), library: library)
        await session.finish(seconds: 2900, duration: 3300)
        // TMDB says 56m, the video is really 55m: the video's own length is used.
        #expect(library.watchedFraction(for: entry, estimatedLength: 3360) == 2900.0 / 3300.0)
        #expect(library.remainingSeconds(for: entry) == 400)

        // The length survives a relaunch.
        try? await Task.sleep(for: .milliseconds(150))
        let next = LibraryIndex(store: LocalStore(fileURL: nil), cache: LibraryCache(fileURL: file))
        next.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await next.loadCached()
        #expect(next.remainingSeconds(for: next.entries.first { $0.id == 11 }!) == 400)
    }

    /// Started on put.io's site or another app: put.io's own length gives the bar and the time left.
    @Test func putioLengthWhenThePlayerNeverSawIt() {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        let file = PutioFile(id: 3, name: "Extremely.Wicked.2019.mkv", fileType: "VIDEO", startFrom: 6000,
                             videoMetadata: PutioFile.VideoMetadata(duration: 6420.4))
        let entry = LibraryEntry(file: file, match: nil, folderName: nil)
        #expect(library.remainingSeconds(for: entry) == 420)
        #expect(library.watchedFraction(for: entry, estimatedLength: 9999) == 6000.0 / 6420.0, "put.io's length beats TMDB's")
        library.noteDuration(fileID: 3, seconds: 6500)
        #expect(library.remainingSeconds(for: entry) == 500, "the player's own length wins")
    }

    /// The Gentlemen S2E4 stopped at the credits on another device: 3 minutes left of 52 is watched here too, so the
    /// next episode comes up. TMDB's estimate alone never decides it.
    @Test func lateStopSavedElsewhereCountsAsWatched() {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        let late = PutioFile(id: 4, name: "The.Gentlemen.S02E04.mkv", fileType: "VIDEO", startFrom: 49 * 60,
                             videoMetadata: PutioFile.VideoMetadata(duration: 52 * 60))
        #expect(library.isWatched(LibraryEntry(file: late, match: nil, folderName: nil)))
        let middle = PutioFile(id: 5, name: "The.Gentlemen.S02E05.mkv", fileType: "VIDEO", startFrom: 30 * 60,
                               videoMetadata: PutioFile.VideoMetadata(duration: 52 * 60))
        #expect(!library.isWatched(LibraryEntry(file: middle, match: nil, folderName: nil)))
        let unknownLength = PutioFile(id: 6, name: "Vision.S01E01.mkv", fileType: "VIDEO", startFrom: 3300)
        #expect(!library.isWatched(LibraryEntry(file: unknownLength, match: nil, folderName: nil)))
        library.noteDuration(fileID: 6, seconds: 3360)
        #expect(library.isWatched(fileID: 6) == false, "no position noted for it here yet")
    }

    @Test func estimateWhenThePlayerNeverSawIt() {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        let file = PutioFile(id: 3, name: "Vision.S01E01.mkv", fileType: "VIDEO", startFrom: 2978)
        let entry = LibraryEntry(file: file, match: nil, folderName: nil)
        #expect(library.watchedFraction(for: entry, estimatedLength: 56 * 60) == 2978.0 / 3360.0)
        #expect(library.watchedFraction(for: entry) == nil, "no length known: no bar")
        #expect(library.remainingSeconds(for: entry, estimatedLength: 56 * 60) == 382)
    }

    @Test func olderCachesWithoutLengthsStillLoad() throws {
        let json = #"{"entries":[],"updatedAt":0}"#
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(json.utf8))
        #expect(snapshot.durations == nil)
    }
}
