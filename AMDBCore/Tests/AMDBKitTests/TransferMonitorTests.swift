import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct TransferMonitorTests {
    struct Rig {
        let putio: FakePutio
        let store: LocalStore
        let clock: TestClock
        let library: LibraryIndex
        let monitor: TransferMonitor

        @MainActor init() {
            let putio = FakePutio()
            let store = LocalStore(fileURL: nil)
            let clock = TestClock()
            let library = LibraryIndex(store: store)
            library.configure(putio: putio, catalog: FakeCatalog())
            let monitor = TransferMonitor(store: store, pollInterval: .seconds(3600), now: { clock.now })
            monitor.configure(putio: putio, library: library)
            self.putio = putio; self.store = store; self.clock = clock; self.library = library; self.monitor = monitor
        }
    }

    let target = TransferTarget(tmdbID: 693134, kind: .movie, title: "Dune: Part Two", posterPath: "/p.jpg",
                                backdropPath: "/b.jpg", season: nil, episode: nil)

    @Test func sendCreatesFolderAddsTransferAndPersists() async throws {
        let rig = Rig()
        let release = makeRelease("a", seeders: 10, name: "Dune.Part.Two.2024.1080p")
        let tracked = try await rig.monitor.send(release, target: target)
        rig.monitor.stop()
        #expect(rig.putio.createdFolders == ["Movies"])
        #expect(rig.putio.added.first?.url == release.link)
        let moviesFolder = await rig.store.snapshot.folderIDs["Movies"]
        #expect(rig.putio.added.first?.parent == moviesFolder)
        #expect(await rig.store.snapshot.pending.map(\.transferID) == [tracked.id])
        #expect(rig.monitor.latest(tmdbID: 693134)?.id == tracked.id)
    }

    @Test func tvGoesToShowAndSeasonFolders() async throws {
        let rig = Rig()
        let tv = TransferTarget(tmdbID: 1, kind: .tv, title: "Severance", posterPath: nil, backdropPath: nil, season: 2, episode: 4)
        _ = try await rig.monitor.send(makeRelease("b", seeders: 5, name: "Severance.S02E04"), target: tv)
        rig.monitor.stop()
        #expect(rig.putio.createdFolders == ["TV Series", "Severance", "Season 2"])
        #expect(rig.putio.added.first?.parent == (await rig.store.snapshot.folderIDs["TV Series/Severance/Season 2"]))

        // Season folders off: straight into the show folder.
        rig.monitor.layout = FolderLayout(movies: nil, tv: nil, seasonFolders: false)
        _ = try await rig.monitor.send(makeRelease("c", seeders: 5, name: "Severance.S02E05"), target: tv)
        rig.monitor.stop()
        #expect(rig.putio.added.last?.parent == (await rig.store.snapshot.folderIDs["TV Series/Severance"]))
    }

    @Test func customBaseFoldersFromSettings() async throws {
        let rig = Rig()
        rig.putio.add(PutioFile(id: 50, name: "Films", fileType: "FOLDER", parentId: 0), to: 0)
        rig.putio.add(PutioFile(id: 60, name: "TV Series", fileType: "FOLDER", parentId: 0), to: 0)
        rig.monitor.layout = FolderLayout(movies: PutioFolderRef(id: 50, path: "Films"), tv: PutioFolderRef(id: 60, path: "TV Series"),
                                          seasonFolders: true)
        _ = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "Dune.Part.Two.2024.1080p"), target: target)
        rig.monitor.stop()
        #expect(rig.putio.added.first?.parent == 50)
        #expect(rig.putio.createdFolders.isEmpty)
        let tv = TransferTarget(tmdbID: 1, kind: .tv, title: "Severance", posterPath: nil, backdropPath: nil, season: 1, episode: nil)
        _ = try await rig.monitor.send(makeRelease("d", seeders: 5, name: "Severance.S01"), target: tv)
        rig.monitor.stop()
        #expect(rig.putio.createdFolders == ["Severance", "Season 1"])
        #expect(FolderLayout(movies: nil, tv: PutioFolderRef(id: 60, path: "TV Series"), seasonFolders: true)
            .displayPath(kind: .tv, title: "AC/DC: Live", season: 1) == "TV Series/AC-DC: Live/Season 1")
    }

    @Test func pollTracksProgressThenCompletes() async throws {
        let rig = Rig()
        var events: [TransferEvent] = []
        rig.monitor.onEvent = { events.append($0) }
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()

        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "DOWNLOADING", percentDone: 50, peersConnected: 9, downloaded: 5))
        await rig.monitor.pollOnce()
        #expect(rig.monitor.tracked.first?.percent == 50)
        #expect(rig.monitor.tracked.first?.phase == .downloading)
        #expect(events.isEmpty)

        rig.putio.add(PutioFile(id: 500, name: "Dune", fileType: "FOLDER"), to: 0)
        rig.putio.add(PutioFile(id: 501, name: "Dune.mkv", fileType: "VIDEO", size: 100), to: 500)
        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", percentDone: 100, fileId: 500))
        await rig.monitor.pollOnce()

        #expect(events.count == 1)
        guard case let .ready(done) = events.first else { Issue.record("expected ready"); return }
        #expect(done.playableFile?.id == 501)
        #expect(rig.library.matching(tmdbID: 693134).map(\.id) == [501])
        #expect(await rig.store.snapshot.pending.isEmpty)

        await rig.monitor.pollOnce()
        #expect(events.count == 1)
    }

    @Test func failureIsReportedOnce() async throws {
        let rig = Rig()
        var events: [TransferEvent] = []
        rig.monitor.onEvent = { events.append($0) }
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "ERROR", errorMessage: "No peers"))
        await rig.monitor.pollOnce()
        await rig.monitor.pollOnce()
        #expect(events.count == 1)
        guard case let .failed(item) = events.first else { Issue.record("expected failed"); return }
        #expect(item.phase == .failed(message: "No peers"))
    }

    @Test func stallIsFlaggedAfterThreeMinutes() async throws {
        let rig = Rig()
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "DOWNLOADING", percentDone: 3, peersConnected: 0, downloaded: 30))
        await rig.monitor.pollOnce()
        rig.clock.advance(200)
        await rig.monitor.pollOnce()
        #expect(rig.monitor.tracked.first?.isStalled == true)
    }

    @Test func restoresPendingTransfers() async {
        let rig = Rig()
        let pending = PendingTransfer(transferID: 9, tmdbID: 1, kind: .movie, title: "X", posterPath: nil, backdropPath: nil,
                                      season: nil, episode: nil, createdAt: Date(timeIntervalSince1970: 0))
        await rig.store.update { $0.pending = [pending] }
        rig.putio.setTransfer(PutioTransfer(id: 9, status: "DOWNLOADING", percentDone: 20))
        await rig.monitor.restore()
        rig.monitor.stop()
        #expect(rig.monitor.tracked.map(\.id) == [9])
        #expect(rig.monitor.tracked.first?.percent == 20)
    }

    @Test func cancelRemovesEverywhere() async throws {
        let rig = Rig()
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        try await rig.monitor.cancel(tracked.id)
        #expect(rig.monitor.tracked.isEmpty)
        #expect(await rig.store.snapshot.pending.isEmpty)
    }

    /// A transfer deleted on put.io's site (404) is dropped, here and from what's restored at the next launch,
    /// instead of being asked about every two seconds forever.
    @Test func aTransferDeletedOnPutioIsDropped() async throws {
        let rig = Rig()
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        try await rig.putio.cancelTransfers(ids: [tracked.id])
        await rig.monitor.pollOnce()
        #expect(rig.monitor.tracked.isEmpty)
        #expect(await rig.store.snapshot.pending.isEmpty)
    }

    /// put.io not answering about a transfer is tried again, but not forever: after `maxFailures` polls in a row
    /// the tile shows it failed, once.
    @Test func repeatedPollFailuresMarkItFailed() async throws {
        let rig = Rig()
        var events: [TransferEvent] = []
        rig.monitor.onEvent = { events.append($0) }
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        rig.putio.failingTransfers = [tracked.id]
        for _ in 0..<(TransferMonitor.maxFailures - 1) { await rig.monitor.pollOnce() }
        #expect(rig.monitor.tracked.first?.notified == false, "still being followed")
        #expect(events.isEmpty)
        await rig.monitor.pollOnce()
        guard case .failed = rig.monitor.tracked.first?.phase else { Issue.record("expected failed"); return }
        #expect(events.count == 1)
        #expect(await rig.store.snapshot.pending.isEmpty)
        await rig.monitor.pollOnce()
        #expect(events.count == 1)
    }

    /// Dismissing a transfer's tile forgets it for the next launch too, so it can't come back from the saved list.
    @Test func dismissForgetsItForTheNextLaunch() async throws {
        let rig = Rig()
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        rig.monitor.dismiss(tracked.id)
        #expect(rig.monitor.tracked.isEmpty)
        for _ in 0..<200 where await !rig.store.snapshot.pending.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await rig.store.snapshot.pending.isEmpty)
        await rig.monitor.restore()
        rig.monitor.stop()
        #expect(rig.monitor.tracked.isEmpty)
    }

    /// Signing out forgets the saved transfers: another account signing in on the device doesn't restore them.
    @Test func signingOutForgetsPendingTransfers() async throws {
        let rig = Rig()
        _ = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: target)
        rig.monitor.stop()
        rig.monitor.configure(putio: nil, library: nil)
        #expect(rig.monitor.tracked.isEmpty)
        for _ in 0..<200 where await !rig.store.snapshot.pending.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await rig.store.snapshot.pending.isEmpty)
        rig.monitor.configure(putio: FakePutio(), library: rig.library)
        await rig.monitor.restore()
        rig.monitor.stop()
        #expect(rig.monitor.tracked.isEmpty)
    }

    @Test func untitledTransfersAreNotRecordedInLibrary() async throws {
        let rig = Rig()
        let untitled = TransferTarget(tmdbID: 0, kind: .movie, title: "Some.Release", posterPath: nil, backdropPath: nil,
                                      season: nil, episode: nil)
        let tracked = try await rig.monitor.send(makeRelease("a", seeders: 10, name: "x"), target: untitled)
        rig.monitor.stop()
        rig.putio.add(PutioFile(id: 700, name: "x.mkv", fileType: "VIDEO", size: 1), to: 0)
        rig.putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", fileId: 700))
        await rig.monitor.pollOnce()
        #expect(rig.monitor.tracked.first?.playableFile?.id == 700)
        #expect(rig.library.matching(tmdbID: 0).isEmpty)
    }
}
