import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct ConversionTests {
    func putio() -> FakePutio {
        let putio = FakePutio()
        putio.add(PutioFile(id: 5, name: "Breaking.Bad.S01E01.avi", fileType: "VIDEO", size: 700), to: 0)
        putio.add(PutioFile(id: 6, name: "Heat.mkv", fileType: "VIDEO", size: 900), to: 0)
        return putio
    }

    @Test func playableVideosNeedNothing() async {
        let putio = putio()
        let conversions = VideoConversions(pollInterval: .milliseconds(1))
        conversions.configure(putio: putio)
        #expect(await conversions.makePlayable(fileID: 6))
        #expect(putio.conversionsStarted.isEmpty)
    }

    @Test func convertsAndWaitsUntilPutioIsDone() async {
        let putio = putio()
        putio.needsMp4 = [5]
        let conversions = VideoConversions(pollInterval: .milliseconds(1))
        conversions.configure(putio: putio)
        #expect(await conversions.needsConversion(fileID: 5))
        #expect(await conversions.makePlayable(fileID: 5))
        #expect(putio.conversionsStarted == [5])
        #expect(conversions.states[5] == nil)
        // Done: it plays as it is from now on.
        #expect(await conversions.needsConversion(fileID: 5) == false)
    }

    @Test func aFailedConversionIsReported() async {
        let putio = putio()
        putio.needsMp4 = [5]
        putio.mp4Progress[5] = [PutioMp4Status(status: .converting, percentDone: 10), PutioMp4Status(status: .error)]
        let conversions = VideoConversions(pollInterval: .milliseconds(1))
        conversions.configure(putio: putio)
        #expect(await conversions.makePlayable(fileID: 5) == false)
        #expect(conversions.states[5] == .failed)
    }

    /// put.io said "completed" without a file id: the file is found by name where the transfer was saved.
    @Test func completedWithoutFileIDFindsTheFileByName() async throws {
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        let monitor = TransferMonitor(store: store, pollInterval: .seconds(3600))
        monitor.configure(putio: putio, library: nil)
        var events: [TransferEvent] = []
        monitor.onEvent = { events.append($0) }
        let target = TransferTarget(tmdbID: 9, kind: .movie, title: "East of Eden", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
        let tracked = try await monitor.send(Release(name: "East.of.Eden", link: "magnet:?xt=urn:btih:ee", sizeBytes: 1,
                                                     seeders: 5, sources: []), target: target)
        monitor.stop()
        let parent = putio.added.first?.parent ?? 0
        putio.add(PutioFile(id: 77, name: "East.of.Eden.1955.1080p.mkv", fileType: "VIDEO", size: 100), to: parent)
        putio.setTransfer(PutioTransfer(id: tracked.id, name: "East.of.Eden.1955.1080p.mkv", status: "COMPLETED",
                                        percentDone: 100, fileId: nil, saveParentId: parent))
        await monitor.pollOnce()
        #expect(monitor.tracked.first?.playableFile?.id == 77)
        #expect(events.count == 1)
    }

    /// A finished transfer whose file never appears is reported after a few minutes, not left spinning.
    @Test func aFinishedTransferWithNoVideoStopsSpinning() async throws {
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        let clock = TestClock()
        let monitor = TransferMonitor(store: store, pollInterval: .seconds(3600), now: { clock.now })
        monitor.configure(putio: putio, library: nil)
        var events: [TransferEvent] = []
        monitor.onEvent = { events.append($0) }
        let target = TransferTarget(tmdbID: 9, kind: .movie, title: "East of Eden", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
        let tracked = try await monitor.send(Release(name: "East.of.Eden", link: "magnet:?xt=urn:btih:ee", sizeBytes: 1,
                                                     seeders: 5, sources: []), target: target)
        monitor.stop()
        putio.add(PutioFile(id: 80, name: "East.of.Eden", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 81, name: "readme.nfo", fileType: "TEXT"), to: 80)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", percentDone: 100, fileId: 80))
        await monitor.pollOnce()
        #expect(events.isEmpty, "waits a little first")
        clock.advance(TransferMonitor.fileGrace + 1)
        await monitor.pollOnce()
        guard case .failed? = events.first else { Issue.record("expected a failed event"); return }
        if case let .failed(message) = monitor.tracked.first?.phase { #expect(message.contains("no video")) }
        #expect(await store.snapshot.pending.isEmpty)
    }

    @Test func videoByExtensionWhenPutioHasNotLabelledItYet() {
        #expect(PutioFile(id: 1, name: "East.of.Eden.mkv", fileType: "OTHER").isVideo)
        #expect(!PutioFile(id: 2, name: "notes.txt", fileType: "TEXT").isVideo)
        #expect(!PutioFile(id: 3, name: "Season.mkv", fileType: "FOLDER").isVideo)
    }
}
