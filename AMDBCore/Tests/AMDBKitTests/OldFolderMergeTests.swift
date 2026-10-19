import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// The merge against a fake put.io: what moves where, running again, failures, and two devices at once.
@MainActor @Suite struct OldFolderMergeTests {
    static func folder(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "FOLDER", parentId: parent)
    }

    static func video(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "VIDEO", size: 1_000, parentId: parent)
    }

    /// root: AMDB { Movies { Dune folder, Heat.1995.mkv, Arrival.2016.mkv }, TV { Severance/Season 2/E04, Andor/Season 1/E01 },
    /// Music { song.mp3 } }, plus the user's own "movies" (holding another Heat.1995.mkv) and "tv series"
    /// (holding Severance/Season 2/E01), and an unrelated "Downloads" folder.
    static func world() -> FakePutio {
        let putio = FakePutio()
        let files: [PutioFile] = [
            folder(1, "AMDB", in: 0),
            folder(2, "Movies", in: 1),
            folder(21, "Dune.Part.Two.2024.1080p", in: 2), video(211, "Dune.Part.Two.2024.1080p.mkv", in: 21),
            video(22, "Heat.1995.mkv", in: 2), video(23, "Arrival.2016.mkv", in: 2),
            folder(3, "TV", in: 1),
            folder(31, "Severance", in: 3), folder(311, "Season 2", in: 31), video(3111, "Severance.S02E04.mkv", in: 311),
            folder(32, "Andor", in: 3), folder(321, "Season 1", in: 32), video(3211, "Andor.S01E01.mkv", in: 321),
            folder(4, "Music", in: 1), PutioFile(id: 41, name: "song.mp3", fileType: "AUDIO", parentId: 4),
            folder(5, "movies", in: 0), video(51, "Heat.1995.mkv", in: 5),
            folder(6, "tv series", in: 0), folder(61, "Severance", in: 6), folder(611, "Season 2", in: 61),
            video(6111, "Severance.S02E01.mkv", in: 611),
            folder(7, "Downloads", in: 0), video(71, "Other.mkv", in: 7),
        ]
        for file in files { putio.add(file, to: file.parentId ?? 0) }
        return putio
    }

    /// Every file (not folder) in the account, by id, wherever it is.
    static func allFiles(_ putio: FakePutio) -> Set<Int64> {
        Set(putio.everything(in: 0).filter { !$0.isFolder }.map(\.id))
    }

    @Test func mergesIntoTheUsersFoldersAndRunsOnce() async {
        let putio = Self.world()
        let before = Self.allFiles(putio)
        let report = await OldFolderMerge.run(putio: putio)

        #expect(report.movies == 3)
        #expect(report.shows == 2)
        #expect(report.renamed == 1)
        #expect(report.leftInAMDB == ["Music"])
        #expect(report.finished)
        #expect(!report.couldNotMove)
        #expect(report.oldFolderIDs == [2, 3])
        #expect(report.message == "Moved 3 movies and 2 shows from AMDB into Movies and TV Series. One had the same name as "
            + "something already there, so it now ends in “(from AMDB)”.")

        // Into the existing folders, found ignoring case; nothing new created.
        #expect(putio.createdFolders.isEmpty)
        #expect(putio.names(in: 5) == ["Arrival.2016.mkv", "Dune.Part.Two.2024.1080p", "Heat.1995 (from AMDB).mkv", "Heat.1995.mkv"])
        #expect(putio.names(in: 6) == ["Andor", "Severance"])
        #expect(putio.names(in: 611) == ["Severance.S02E01.mkv", "Severance.S02E04.mkv"])
        #expect(putio.names(in: 1) == ["Music"], "AMDB keeps what isn't Movies or TV")
        #expect(putio.names(in: 7) == ["Other.mkv"])
        // Only emptied folders were deleted (to the Trash); every file is still there.
        #expect(Set(putio.deleted) == [2, 3, 31, 311])
        #expect(Self.allFiles(putio) == before)

        // Again (next launch, or another device afterwards): nothing to do, nothing changes.
        let calls = (putio.moved.count, putio.renamed.count, putio.deleted.count, putio.createdFolders.count)
        let again = await OldFolderMerge.run(putio: putio)
        #expect(again.finished)
        #expect(again.message == nil)
        #expect(!again.changedPutio)
        #expect((putio.moved.count, putio.renamed.count, putio.deleted.count, putio.createdFolders.count) == calls)
    }

    @Test func createsMissingFoldersAndDeletesAnEmptyAMDB() async {
        let putio = FakePutio()
        for file in [Self.folder(1, "AMDB", in: 0), Self.folder(2, "Movies", in: 1), Self.video(21, "Heat.1995.mkv", in: 2)] {
            putio.add(file, to: file.parentId ?? 0)
        }
        let report = await OldFolderMerge.run(putio: putio)
        #expect(putio.createdFolders == ["Movies"], "TV Series isn't needed: there was no AMDB/TV")
        #expect(report.movies == 1)
        #expect(report.message == "Moved 1 movie from AMDB into Movies.")
        #expect(Set(putio.deleted) == [2, 1])
        #expect(putio.names(in: 0) == ["Movies"])
        #expect(report.finished)
    }

    @Test func nothingToMergeIsANoOp() async {
        let putio = FakePutio()
        putio.add(Self.folder(7, "Downloads", in: 0), to: 0)
        let report = await OldFolderMerge.run(putio: putio)
        #expect(report.finished)
        #expect(report.message == nil)
        #expect(putio.moved.isEmpty && putio.deleted.isEmpty && putio.createdFolders.isEmpty)
    }

    /// A move fails part-way: what moved stays moved, nothing is deleted that still holds something, the user hears
    /// about it, and the next run finishes the job.
    @Test func stopsOnAFailedMoveAndResumesNextTime() async {
        let putio = Self.world()
        let before = Self.allFiles(putio)
        putio.failingMoves = [32]  // the batch that moves Andor
        let first = await OldFolderMerge.run(putio: putio)
        #expect(first.couldNotMove)
        #expect(!first.finished)
        #expect(first.movies == 3, "movies were merged before the failure and stay merged")
        #expect(first.shows == 0)
        #expect(first.message?.hasSuffix("Some things in AMDB couldn't be moved yet. The app will try again next time.") == true)
        #expect(!putio.deleted.contains(3), "AMDB/TV still holds Andor and Severance")
        #expect(Self.allFiles(putio) == before)

        putio.failingMoves = []
        let second = await OldFolderMerge.run(putio: putio)
        #expect(!second.couldNotMove)
        #expect(second.finished)
        #expect(second.movies == 0)
        #expect(second.shows == 2)
        #expect(putio.names(in: 6) == ["Andor", "Severance"])
        #expect(putio.names(in: 611) == ["Severance.S02E01.mkv", "Severance.S02E04.mkv"])
        #expect(putio.names(in: 1) == ["Music"])
        #expect(Self.allFiles(putio) == before)
    }

    @Test func aFailedRenameStopsBeforeTheMove() async {
        let putio = Self.world()
        putio.failingRenames = [22]
        let report = await OldFolderMerge.run(putio: putio)
        #expect(report.couldNotMove)
        #expect(putio.names(in: 2) == ["Arrival.2016.mkv", "Dune.Part.Two.2024.1080p", "Heat.1995.mkv"], "nothing moved past the failure")
        #expect(putio.names(in: 5) == ["Heat.1995.mkv"], "the user's Heat is untouched")
    }

    /// A folder is deleted only if it's empty right then: a download landing in it meanwhile keeps it (and the
    /// merge isn't finished, so the next launch moves the newcomer too).
    @Test func keepsAFolderThatFilledUpMeanwhile() async {
        let putio = Self.world()
        let landed = Self.video(9999, "Severance.S02E05.mkv", in: 311)
        let once = OnceFlag()
        putio.afterMove = { if once.take() { putio.add(landed, to: 311) } }
        let report = await OldFolderMerge.run(putio: putio)
        #expect(!putio.deleted.contains(311))
        #expect(!report.finished)
        #expect(putio.names(in: 311) == ["Severance.S02E05.mkv"])

        putio.afterMove = nil
        let next = await OldFolderMerge.run(putio: putio)
        #expect(next.finished)
        #expect(putio.names(in: 611) == ["Severance.S02E01.mkv", "Severance.S02E04.mkv", "Severance.S02E05.mkv"])
    }

    /// A folder an unfinished transfer saves into stays even when empty.
    @Test func keepsTheFolderOfARunningTransfer() async {
        let putio = Self.world()
        putio.setTransfer(PutioTransfer(id: 1, status: "DOWNLOADING", saveParentId: 311))
        let report = await OldFolderMerge.run(putio: putio)
        #expect(!putio.deleted.contains(311))
        #expect(!report.finished)
        putio.setTransfer(PutioTransfer(id: 1, status: "COMPLETED", saveParentId: 311))
        #expect(await OldFolderMerge.run(putio: putio).finished)
        #expect(putio.deleted.contains(311))
    }

    /// Two devices merging at the same moment: whatever order their calls land in, no file is lost or deleted.
    @Test func twoDevicesAtOnceLoseNothing() async {
        let putio = Self.world()
        let before = Self.allFiles(putio)
        async let a = OldFolderMerge.run(putio: putio)
        async let b = OldFolderMerge.run(putio: putio)
        _ = await (a, b)
        let third = await OldFolderMerge.run(putio: putio)
        #expect(third.finished)
        #expect(Self.allFiles(putio) == before)
        let merged = Set(putio.everything(in: 5).map(\.id) + putio.everything(in: 6).map(\.id))
        #expect(merged.isSuperset(of: [211, 22, 23, 51, 3111, 3211, 6111]))
    }

    // MARK: In the app

    func model(_ putio: FakePutio, defaults: UserDefaults) -> AppModel {
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in FakeCatalog() }, makeProvider: { _, _ in nil })
        return AppModel(tokens: InMemoryTokenStore([.putio: "p", .tmdb: "t"]), defaults: defaults, store: LocalStore(fileURL: nil),
                        factory: factory)
    }

    /// Runs once per account on a device; the library is read again afterwards; a Settings pick of an old folder
    /// goes back to the default.
    @Test func appRunsItOncePerAccountAndRefreshesTheLibrary() async {
        let putio = Self.world()
        let defaults = testDefaults()
        var saved = AppSettings.defaults
        saved.tvFolder = PutioFolderRef(id: 3, path: "Media/Renamed TV")  // the old AMDB/TV, picked by id
        saved.save(to: defaults)
        let app = model(putio, defaults: defaults)
        #expect(app.settings.tvFolder?.id == 3)

        let report = await app.mergeOldFoldersIfNeeded()
        #expect(report?.shows == 2)
        #expect(app.settings.tvFolder == nil)
        #expect(app.library.entries.map(\.id).contains(3111), "the library was read again, from TV Series")
        #expect(!app.library.entries.map(\.id).contains(71), "Downloads isn't part of the library")
        #expect(await app.mergeOldFoldersIfNeeded() == nil, "already done for this account")

        // A fresh launch on the same device: still done.
        #expect(await model(putio, defaults: defaults).mergeOldFoldersIfNeeded() == nil)
    }

    @Test func notDoneUntilFinished() async {
        let putio = Self.world()
        putio.failingMoves = [32]
        let defaults = testDefaults()
        let app = model(putio, defaults: defaults)
        #expect(await app.mergeOldFoldersIfNeeded()?.couldNotMove == true)
        putio.failingMoves = []
        #expect(await app.mergeOldFoldersIfNeeded()?.finished == true, "tried again (next launch)")
        #expect(await app.mergeOldFoldersIfNeeded() == nil)
    }

    @Test func demoModeNeverMerges() async {
        let putio = Self.world()
        let app = model(putio, defaults: testDefaults())
        app.mergesOldFolders = false
        #expect(await app.mergeOldFoldersIfNeeded() == nil)
        #expect(putio.moved.isEmpty)
    }
}

/// True the first time only (thread-safe), for one-shot hooks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
