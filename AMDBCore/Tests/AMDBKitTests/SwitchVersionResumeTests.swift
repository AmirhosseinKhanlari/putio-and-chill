import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// Switching versions partway through: the 1080p was watched to the middle, the 4K goes on from there (and back).
/// Each file keeps its own position; the carried one only decides where a copy starts.
@MainActor @Suite struct SwitchVersionResumeTests {
    static let dune = LibraryMatch(tmdbID: 693134, mediaType: .movie, season: nil, episode: nil, confidence: 1)
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func library(_ files: [(Int64, LibraryMatch)]) async -> LibraryIndex {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: FakePutio(), catalog: TitleModelTests.catalog)
        for (id, match) in files {
            await library.record(file: PutioFile(id: id, name: "\(id).mkv", fileType: "VIDEO", startFrom: 0), match: match)
        }
        return library
    }

    /// Files as put.io lists them: positions only from `start_from`, no stamps.
    func putioLibrary(_ files: [(Int64, Int)]) async -> LibraryIndex {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: FakePutio(), catalog: TitleModelTests.catalog)
        for (id, start) in files {
            await library.record(file: PutioFile(id: id, name: "\(id).mkv", fileType: "VIDEO", startFrom: start), match: Self.dune)
        }
        return library
    }

    func entry(_ library: LibraryIndex, _ id: Int64) -> LibraryEntry { library.entries.first { $0.id == id }! }

    static func episode(_ season: Int, _ episode: Int) -> LibraryMatch {
        LibraryMatch(tmdbID: 95396, mediaType: .tv, season: season, episode: episode, confidence: 1)
    }

    @Test func anotherCopyStartsWhereTheFirstWasLeft() async {
        let library = await library([(1, Self.dune), (2, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 3733, now: Self.t0)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 3733)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 3733)
        // Nothing stored for the other copy: its own position, progress bar and watched state are unchanged.
        #expect(library.resumeSeconds(for: entry(library, 2)) == 0)
        #expect(library.pendingPositions.map(\.fileID) == [1])
    }

    @Test func theNewestPositionWins() async {
        let library = await library([(1, Self.dune), (2, Self.dune), (3, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 3000, now: Self.t0)
        library.noteProgress(fileID: 2, seconds: 1200, now: Self.t0.addingTimeInterval(60))
        #expect(library.resumeSeconds(forTitleOf: entry(library, 3)) == 1200, "newer, though not further")
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 1200, "an older own position gives way")
    }

    @Test func aCopyWithItsOwnNewerPositionKeepsIt() async {
        let library = await library([(1, Self.dune), (2, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 3000, now: Self.t0)
        library.noteProgress(fileID: 2, seconds: 3100, now: Self.t0.addingTimeInterval(60))
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 3100)
        // Started over on the new copy: that's where it is now, not where the old one was.
        library.noteProgress(fileID: 2, seconds: 40, now: Self.t0.addingTimeInterval(120))
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 40)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 40)
    }

    @Test func episodesCarryOnlyBetweenCopiesOfTheSameEpisode() async {
        let library = await library([(1, Self.episode(1, 3)), (2, Self.episode(1, 3)), (3, Self.episode(1, 4)),
                                     (4, Self.episode(2, 3)), (5, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 1500, now: Self.t0)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 1500)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 3)) == 0, "another episode")
        #expect(library.resumeSeconds(forTitleOf: entry(library, 4)) == 0, "same episode number, another season")
        #expect(library.resumeSeconds(forTitleOf: entry(library, 5)) == 0, "another title")
    }

    @Test func aMovieAndAShowWithTheSameTMDBIDDontShare() async {
        let show = LibraryMatch(tmdbID: 693134, mediaType: .tv, season: 1, episode: 1, confidence: 1)
        let library = await library([(1, Self.dune), (2, show)])
        library.noteProgress(fileID: 1, seconds: 1500, now: Self.t0)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 0)
    }

    @Test func aCopyWatchedToTheEndDoesntResumeAnotherAtAnOlderPosition() async {
        let library = await library([(1, Self.dune), (2, Self.dune), (3, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 3000, now: Self.t0)
        library.noteProgress(fileID: 2, seconds: 0, now: Self.t0.addingTimeInterval(3600), watched: true)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 0, "its own mid position is older than the end")
        #expect(library.resumeSeconds(forTitleOf: entry(library, 3)) == 0)
        // Its own position stays as it was.
        #expect(library.resumeSeconds(for: entry(library, 1)) == 3000)
    }

    @Test func aPositionInTheCreditsCountsAsWatched() async {
        let library = await library([(1, Self.dune), (2, Self.dune)])
        library.noteDuration(fileID: 1, seconds: 6000)
        library.noteProgress(fileID: 1, seconds: 5950, now: Self.t0)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 0)
    }

    @Test func aPositionPastTheEndOfAShorterCopyStartsItOver() async {
        let library = await library([(1, Self.dune), (2, Self.dune)])
        library.noteDuration(fileID: 2, seconds: 3000)
        library.noteProgress(fileID: 1, seconds: 3500, now: Self.t0)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 0)
    }

    @Test func aNewCopyNotInTheLibraryYetCarriesToo() async {
        let library = await library([(1, Self.dune)])
        library.noteProgress(fileID: 1, seconds: 3733, now: Self.t0)
        // A transfer that just finished: played before the next library update finds it.
        let new = LibraryEntry(file: PutioFile(id: 9, name: "Dune.2160p.mkv", fileType: "VIDEO"), match: Self.dune, folderName: nil)
        #expect(library.resumeSeconds(forTitleOf: new) == 3733)
        #expect(await library.freshResumeSeconds(forTitleOf: new, timeout: .milliseconds(500)) == 3733)
    }

    @Test func titleActionResumesTheCopyWatchedLast() async {
        let store = LocalStore(fileURL: nil)
        let library = await library([(1, Self.dune), (2, Self.dune)])
        let model = TitleModel(item: TitleModelTests.dune, catalog: TitleModelTests.catalog, library: library,
                               transfers: TransferMonitor(store: store, pollInterval: .seconds(3600)))
        library.noteProgress(fileID: 1, seconds: 3000, now: Self.t0)
        #expect(model.action() == .resume(entry(library, 1), seconds: 3000))
        // Switched to the other copy and watched a little further.
        library.noteProgress(fileID: 2, seconds: 3100, now: Self.t0.addingTimeInterval(120))
        #expect(model.action() == .resume(entry(library, 2), seconds: 3100))
        // Then watched to the end: nothing to resume, though the first copy was left in the middle.
        library.noteProgress(fileID: 2, seconds: 0, now: Self.t0.addingTimeInterval(4000), watched: true)
        guard case let .play(best) = model.action() else { Issue.record("expected play"); return }
        #expect(best.id == 2)
    }

    @Test func aShortPeekAtAnotherCopyDoesntHideTheRealPosition() async {
        let store = LocalStore(fileURL: nil)
        let library = await library([(1, Self.dune), (2, Self.dune)])
        let model = TitleModel(item: TitleModelTests.dune, catalog: TitleModelTests.catalog, library: library,
                               transfers: TransferMonitor(store: store, pollInterval: .seconds(3600)))
        library.noteProgress(fileID: 1, seconds: 3733, now: Self.t0)
        library.noteProgress(fileID: 2, seconds: 5, now: Self.t0.addingTimeInterval(60))
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 3733)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 3733, "the peeked copy starts where the real watching was")
        #expect(model.action() == .resume(entry(library, 1), seconds: 3733))
        #expect(library.continueWatchingCards == [.resume(entry(library, 1))])
        #expect(library.resumeSeconds(for: entry(library, 1)) == 3733)
    }

    @Test func putioOnlyPositionsGoByFurthestWhenNoneIsStamped() async {
        let library = await putioLibrary([(1, 3000), (2, 1200), (3, 0)])
        #expect(library.resumeSeconds(forTitleOf: entry(library, 3)) == 3000)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 3000)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 1200, "own position, no way to tell which is newer")
    }

    @Test func aPutioOnlyShortPeekIsIgnored() async {
        let library = await putioLibrary([(1, 3000), (2, 5)])
        #expect(library.resumeSeconds(forTitleOf: entry(library, 2)) == 3000)
        #expect(library.resumeSeconds(forTitleOf: entry(library, 1)) == 3000)
    }
}
