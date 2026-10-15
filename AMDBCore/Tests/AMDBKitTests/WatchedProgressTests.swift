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
        await session.finish(seconds: 2978, duration: 3300)
        // TMDB says 56m, the video is really 55m: the video's own length is used.
        #expect(library.watchedFraction(for: entry, estimatedLength: 3360) == 2978.0 / 3300.0)
        #expect(library.remainingSeconds(for: entry) == 322)

        // The length survives a relaunch.
        try? await Task.sleep(for: .milliseconds(150))
        let next = LibraryIndex(store: LocalStore(fileURL: nil), cache: LibraryCache(fileURL: file))
        next.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        await next.loadCached()
        #expect(next.remainingSeconds(for: next.entries.first { $0.id == 11 }!) == 322)
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
