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
        #expect(rig.putio.createdFolders == ["AMDB", "Movies"])
        #expect(rig.putio.added.first?.url == release.link)
        let moviesFolder = await rig.store.snapshot.folderIDs["AMDB/Movies"]
        #expect(rig.putio.added.first?.parent == moviesFolder)
        #expect(await rig.store.snapshot.pending.map(\.transferID) == [tracked.id])
        #expect(rig.monitor.latest(tmdbID: 693134)?.id == tracked.id)
    }

    @Test func tvTargetsUseShowFolder() {
        let tv = TransferTarget(tmdbID: 1, kind: .tv, title: "Severance", posterPath: nil, backdropPath: nil, season: 2, episode: 4)
        #expect(tv.folderPath == ["AMDB", "TV", "Severance"])
        #expect(target.folderPath == ["AMDB", "Movies"])
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
