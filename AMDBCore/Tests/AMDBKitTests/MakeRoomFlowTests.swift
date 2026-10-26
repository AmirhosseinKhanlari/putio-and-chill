import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// put.io whose free space follows what's in it: `size` minus every file, and (with `trashCounts`) minus the Trash.
final class SpacePutio: PutioService, @unchecked Sendable {
    let base = FakePutio()
    private let lock = NSLock()
    var size: Int64 = 30_000
    var trashCounts = false
    /// Account info stops answering (to check put.io deciding on its own).
    var accountFails = false
    private(set) var deleteCalls: [[Int64]] = []
    private(set) var trashDeleteCalls: [[Int64]] = []
    private(set) var retried: [Int64] = []

    var used: Int64 {
        let files = base.everything(in: 0).filter { !$0.isFolder }.compactMap(\.size).reduce(0, +)
        return files + (trashCounts ? base.trashed.compactMap(\.size).reduce(0, +) : 0)
    }

    func accountInfo() async throws -> PutioAccount {
        if lock.withLock({ accountFails }) { throw AppError.transport("offline") }
        return PutioAccount(username: "me", disk: .init(avail: size - used, size: size, used: used), trashSize: 0)
    }
    func deleteFiles(ids: [Int64]) async throws {
        lock.withLock { deleteCalls.append(ids) }
        try await base.deleteFiles(ids: ids)
    }
    func deleteFromTrash(ids: [Int64]) async throws {
        lock.withLock { trashDeleteCalls.append(ids) }
        try await base.deleteFromTrash(ids: ids)
    }
    func emptyTrash() async throws { Issue.record("the whole Trash must never be emptied") }
    func retryTransfer(id: Int64) async throws -> PutioTransfer {
        lock.withLock { retried.append(id) }
        return PutioTransfer(id: id, name: "t", status: "IN_QUEUE", percentDone: 0)
    }

    func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer { try await base.addTransfer(url: url, saveParentID: saveParentID) }
    func transfer(id: Int64) async throws -> PutioTransfer { try await base.transfer(id: id) }
    func transfers() async throws -> [PutioTransfer] { try await base.transfers() }
    func cancelTransfers(ids: [Int64]) async throws { try await base.cancelTransfers(ids: ids) }
    func listFiles(parentID: Int64) async throws -> PutioFileList { try await base.listFiles(parentID: parentID) }
    func file(id: Int64) async throws -> PutioFile { try await base.file(id: id) }
    func createFolder(name: String, parentID: Int64) async throws -> PutioFile { try await base.createFolder(name: name, parentID: parentID) }
    func moveFiles(ids: [Int64], to parentID: Int64) async throws { try await base.moveFiles(ids: ids, to: parentID) }
    func renameFile(id: Int64, name: String) async throws { try await base.renameFile(id: id, name: name) }
    func fileStatus(id: Int64) async throws -> PutioFile { try await base.fileStatus(id: id) }
    func mp4Status(fileID: Int64) async throws -> PutioMp4Status { try await base.mp4Status(fileID: fileID) }
    func mediaInfo(fileID: Int64) async throws -> PutioMediaInfo { try await base.mediaInfo(fileID: fileID) }
    func convertToMp4(fileID: Int64) async throws -> PutioMp4Status { try await base.convertToMp4(fileID: fileID) }
    func copyFile(id: Int64, to parentID: Int64) async throws -> PutioFile { try await base.copyFile(id: id, to: parentID) }
    func searchFiles(_ query: String) async throws -> [PutioFile] { try await base.searchFiles(query) }
    func trash() async throws -> PutioTrash { try await base.trash() }
    func restoreFromTrash(ids: [Int64]) async throws { try await base.restoreFromTrash(ids: ids) }
    func startFrom(fileID: Int64) async throws -> Int { try await base.startFrom(fileID: fileID) }
    func setStartFrom(fileID: Int64, seconds: Int) async throws { try await base.setStartFrom(fileID: fileID, seconds: seconds) }
    func resetStartFrom(fileID: Int64) async throws { try await base.resetStartFrom(fileID: fileID) }
    func hlsURL(fileID: Int64, subtitles: Bool) -> URL { base.hlsURL(fileID: fileID, subtitles: subtitles) }
    func hlsURL(fileID: Int64, subtitleKey: String) -> URL { base.hlsURL(fileID: fileID, subtitleKey: subtitleKey) }
    func originalURL(fileID: Int64) async throws -> URL { try await base.originalURL(fileID: fileID) }
    func subtitles(fileID: Int64) async throws -> [PutioSubtitle] { try await base.subtitles(fileID: fileID) }
    func subtitleText(fileID: Int64, key: String) async throws -> String { try await base.subtitleText(fileID: fileID, key: key) }
}

@MainActor @Suite struct MakeRoomFlowTests {
    struct Rig {
        let putio = SpacePutio()
        let store = LocalStore(fileURL: nil)
        let library: LibraryIndex
        let monitor: TransferMonitor

        @MainActor init() async {
            library = LibraryIndex(store: store)
            monitor = TransferMonitor(store: store, pollInterval: .seconds(3600))
            // The fixture's put.io: everything in Movies, TV Series, Other and at the top.
            for folder in RoomFixture.folders { putio.base.add(folder, to: folder.parentId ?? 0) }
            for entry in RoomFixture.entries { putio.base.add(entry.file, to: entry.file.parentId ?? 0) }
            let matches = Dictionary(uniqueKeysWithValues: RoomFixture.entries.compactMap { entry in entry.match.map { (entry.id, $0) } })
            await store.update { $0.matches = matches; $0.myList = [SavedTitle(CatalogItem(tmdbID: 4, mediaType: .movie, title: "Movie 4"))] }
            library.configure(putio: putio, catalog: FakeCatalog())
            monitor.configure(putio: putio, library: library)
            await library.refresh()
            library.noteProgress(fileID: 131, seconds: 600)
        }

        /// The fixture's plan for freeing `needed` (watched from the fixture, not the player).
        @MainActor func plan(_ needed: Int64, target: TransferTarget? = nil) -> RoomPlan {
            var rules = RoomFixture.rules
            rules.target = target
            return RoomPlanner.plan(needed: needed, entries: library.entries, folders: Array(library.folderTree.folders.values), rules: rules)
        }

        @MainActor func session(size: Int64, plan: RoomPlan, action: RoomAction = .retry(transferID: 77)) async throws -> RoomSession {
            let avail = try await putio.accountInfo().disk!.avail
            let offer = RoomOffer(title: "Dune", size: size, avail: avail, plan: plan, action: action, target: nil)
            return monitor.room.session(for: offer)
        }
    }

    let dune = TransferTarget(tmdbID: 693134, kind: .movie, title: "Dune: Part Two", posterPath: nil, backdropPath: nil,
                              season: nil, episode: nil)

    func release(_ size: Int64?) -> Release {
        var release = makeRelease("d", seeders: 10, name: "Dune.Part.Two.2024.1080p")
        release.sizeBytes = size
        return release
    }

    @Test func aReleaseThatDoesntFitIsntSent() async throws {
        let rig = await Rig()
        let avail = try await rig.putio.accountInfo().disk!.avail
        await #expect(throws: NotEnoughSpace.self) { try await rig.monitor.send(release(avail), target: dune) }
        #expect(rig.putio.base.added.isEmpty)
        // It's offered once to the screen that asked.
        #expect(rig.monitor.room.presentRefusal(for: dune))
        let offer = try #require(rig.monitor.room.offer)
        #expect(offer.size == avail && offer.avail == avail && offer.needed == SpaceCheck.required(size: avail) - avail)
        #expect(offer.plan?.isEnough == true)
        #expect(offer.action == .send(release(avail), dune))
        #expect(!rig.monitor.room.presentRefusal(for: dune))
    }

    @Test func fitsOrUnknownSizeIsSentWithoutAsking() async throws {
        let rig = await Rig()
        let avail = try await rig.putio.accountInfo().disk!.avail
        _ = try await rig.monitor.send(release(Int64(Double(avail) / 1.02) - 1), target: dune)
        _ = try await rig.monitor.send(release(nil), target: dune)
        // put.io not answering: put.io decides.
        rig.putio.accountFails = true
        _ = try await rig.monitor.send(release(avail * 10), target: dune)
        rig.monitor.stop()
        #expect(rig.putio.base.added.count == 3)
        #expect(rig.putio.deleteCalls.isEmpty)
    }

    @Test func turnedOffOnlySaysSo() async throws {
        let rig = await Rig()
        rig.monitor.room.isEnabled = false
        let avail = try await rig.putio.accountInfo().disk!.avail
        do {
            try await rig.monitor.send(release(avail), target: dune)
            Issue.record("expected NotEnoughSpace")
        } catch let error as NotEnoughSpace {
            #expect(error.offer.plan == nil && !error.offer.canMakeRoom)
            #expect(error.localizedDescription.hasPrefix("Not enough space on put.io."))
        }
        #expect(rig.putio.deleteCalls.isEmpty)
    }

    @Test func deletesOnlyTheConfirmedItemsThenSends() async throws {
        let rig = await Rig()
        let avail = try await rig.putio.accountInfo().disk!.avail
        let size = avail + 5000
        let plan = rig.plan(SpaceCheck.required(size: size) - avail)
        let session = try await rig.session(size: size, plan: plan, action: .send(release(size), dune))
        #expect(session.selection == [22])           // Season 1 (6000) is enough
        // Unticked: not enough, so it can't run.
        session.toggle(22)
        #expect(!session.canDelete)
        await session.confirm()
        #expect(rig.putio.deleteCalls.isEmpty)
        // Season 2 and the old movie instead.
        session.toggle(23)
        session.toggle(11)
        #expect(session.freed == 6600 && session.canDelete)
        await session.confirm()
        #expect(rig.putio.deleteCalls == [[23, 11]])
        #expect(rig.putio.trashDeleteCalls.isEmpty)
        #expect(session.phase == .done("Freed \(RoomFormat.bytes(6600)) · Getting Dune"))
        #expect(rig.putio.base.added.count == 1)
        // The library forgot what went.
        #expect(!rig.library.entries.contains { [231, 111].contains($0.id) })
        rig.monitor.stop()
    }

    @Test func deletedItemsStillInTheTrashAreRemovedOnlyAfterAskingAndOnlyThose() async throws {
        let rig = await Rig()
        rig.putio.trashCounts = true
        // Something else is already in the Trash: it must stay.
        try await rig.putio.base.deleteFiles(ids: [301])
        let avail = try await rig.putio.accountInfo().disk!.avail
        let size = avail + 2000
        let session = try await rig.session(size: size, plan: rig.plan(SpaceCheck.required(size: size) - avail))
        #expect(session.selection == [22])
        await session.confirm()
        #expect(rig.putio.deleteCalls == [[22]])
        guard case let .trash(items) = session.phase else { Issue.record("expected the Trash question, got \(session.phase)"); return }
        #expect(items.map(\.id) == [22])
        #expect(rig.putio.retried.isEmpty)
        await session.purgeTrash()
        #expect(rig.putio.trashDeleteCalls == [[22]])
        #expect(rig.putio.base.trashed.map(\.id) == [301])
        #expect(rig.putio.retried == [77])
        if case .done = session.phase {} else { Issue.record("expected done, got \(session.phase)") }
    }

    @Test func keepingThemInTheTrashSendsNothing() async throws {
        let rig = await Rig()
        rig.putio.trashCounts = true
        let avail = try await rig.putio.accountInfo().disk!.avail
        let session = try await rig.session(size: avail + 100, plan: rig.plan(SpaceCheck.required(size: avail + 100) - avail))
        await session.confirm()
        session.keepInTrash()
        if case let .failed(message) = session.phase { #expect(message.contains("Trash")) } else { Issue.record("\(session.phase)") }
        #expect(rig.putio.trashDeleteCalls.isEmpty && rig.putio.retried.isEmpty)
    }

    @Test func stillNotEnoughAfterTheTrashSaysSoAndSendsNothing() async throws {
        let rig = await Rig()
        let avail = try await rig.putio.accountInfo().disk!.avail
        let session = try await rig.session(size: avail + 100, plan: rig.plan(SpaceCheck.required(size: avail + 100) - avail))
        // put.io's free space doesn't move at all (its accounting lags), even once the Trash is cleared.
        rig.putio.size -= 6000
        await session.confirm()
        guard case .trash = session.phase else { Issue.record("\(session.phase)"); return }
        await session.purgeTrash()
        if case let .failed(message) = session.phase {
            #expect(message.contains("still shows only"))
        } else {
            Issue.record("\(session.phase)")
        }
        #expect(rig.putio.retried.isEmpty)
    }

    @Test func aFolderThatGotNewVideosIsntDeleted() async throws {
        let rig = await Rig()
        // A new episode landed in Season 1 after the library was read.
        rig.putio.base.add(RoomFixture.video(223, "S01E03.mkv", parent: 22, size: 3000, added: "2026-10-01T00:00:00"), to: 22)
        rig.putio.size += 3000
        let avail = try await rig.putio.accountInfo().disk!.avail
        let session = try await rig.session(size: avail + 100, plan: rig.plan(SpaceCheck.required(size: avail + 100) - avail))
        #expect(session.selection == [22])
        await session.confirm()
        #expect(rig.putio.deleteCalls.isEmpty)
        if case let .failed(message) = session.phase { #expect(message.contains("Nothing was deleted")) } else { Issue.record("\(session.phase)") }
    }

    @Test func notEnoughEvenWithEverythingDeletesNothing() async throws {
        let rig = await Rig()
        let session = try await rig.session(size: 1_000_000, plan: rig.plan(1_000_000))
        #expect(session.selection.isEmpty && !session.canDelete)
        session.toggle(22)
        await session.confirm()
        #expect(rig.putio.deleteCalls.isEmpty)
    }

    @Test func theRoomKeeperPlansFromTheLibrary() async throws {
        let rig = await Rig()
        let plan = await rig.monitor.room.plan(needed: 1, target: dune)
        let ids = plan.candidates.map(\.id)
        // Not watched by the player here, so all unwatched, oldest first; at 10 minutes and My List stay.
        #expect(!ids.contains(13) && !ids.contains(14) && !ids.contains(30) && !ids.contains(5))
        #expect(ids.first == 22)
        // A download saving into Season 1 keeps it.
        rig.putio.base.setTransfer(PutioTransfer(id: 5, status: "DOWNLOADING", saveParentId: 22))
        let pending = PendingTransfer(transferID: 5, tmdbID: 100, kind: .tv, title: "Show", posterPath: nil, backdropPath: nil,
                                      season: 1, episode: 3, createdAt: Date())
        await rig.store.update { $0.pending = [pending] }
        await rig.monitor.restore()
        rig.monitor.stop()
        #expect(!(await rig.monitor.room.plan(needed: 1, target: nil)).candidates.contains { $0.id == 22 })
    }

    @Test func aTransferThatRanOutOfSpaceIsRetriedAfterMakingRoom() async throws {
        let rig = await Rig()
        let avail = try await rig.putio.accountInfo().disk!.avail
        rig.putio.base.setTransfer(PutioTransfer(id: 9, name: "Dune", status: "ERROR", size: avail + 1000,
                                                 errorMessage: "Not enough disk space"))
        let pending = PendingTransfer(transferID: 9, tmdbID: 693134, kind: .movie, title: "Dune: Part Two", posterPath: nil,
                                      backdropPath: nil, season: nil, episode: nil, createdAt: Date())
        await rig.store.update { $0.pending = [pending] }
        await rig.monitor.restore()
        rig.monitor.stop()
        let failed = try #require(rig.monitor.tracked.first { $0.id == 9 })
        #expect(OutOfSpace.matches(failed))
        guard case let .offer(offer) = await rig.monitor.room.prepareRetry(failed) else { Issue.record("expected an offer"); return }
        #expect(offer.action == .retry(transferID: 9) && offer.title == "Dune: Part Two")
        let session = rig.monitor.room.session(for: offer)
        await session.confirm()
        #expect(rig.putio.retried == [9])
        #expect(rig.monitor.tracked.first { $0.id == 9 }?.phase == .queued)
        #expect(await rig.store.snapshot.pending.map(\.transferID) == [9])
        rig.monitor.stop()
    }
}
