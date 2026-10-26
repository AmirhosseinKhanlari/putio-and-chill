import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct FakeDownloadTests {
    let target = TransferTarget(tmdbID: 693134, kind: .movie, title: "Dune: Part Two", posterPath: nil,
                                backdropPath: nil, season: nil, episode: nil)
    let hashA = String(repeating: "a", count: 40)

    let clock = TestClock()

    func rig() -> (FakePutio, LocalStore, LibraryIndex, TransferMonitor) {
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        let library = LibraryIndex(store: store)
        library.configure(putio: putio, catalog: FakeCatalog())
        let clock = clock
        let monitor = TransferMonitor(store: store, pollInterval: .seconds(3600), now: { clock.now })
        monitor.configure(putio: putio, library: library)
        return (putio, store, library, monitor)
    }

    @Test func finishedDownloadWithAProgramIsRemovedAndRemembered() async throws {
        let (putio, store, library, monitor) = rig()
        var events: [TransferEvent] = []
        monitor.onEvent = { events.append($0) }
        let release = makeRelease("a", seeders: 10, name: "Dune.Part.Two.2024.1080p.WEB-DL")
        let tracked = try await monitor.send(release, target: target)
        monitor.stop()
        putio.add(PutioFile(id: 500, name: "Dune.Part.Two.2024.1080p.WEB-DL", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 501, name: "Dune.Part.Two.2024.1080p.wmv", fileType: "VIDEO", size: 90_000_000), to: 500)
        putio.add(PutioFile(id: 502, name: "Codec", fileType: "FOLDER"), to: 500)
        putio.add(PutioFile(id: 503, name: "Install Codec.exe", fileType: "FILE", size: 3_000_000), to: 502)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", percentDone: 100, hash: hashA.uppercased(), fileId: 500))
        await monitor.pollOnce()

        #expect(events.count == 1)
        guard case let .failed(item) = events.first else { Issue.record("expected failed, got \(events)"); return }
        #expect(item.phase == .failed(message: DownloadCheck.fakeMessage))
        #expect(item.playableFile == nil)
        #expect(putio.deleted == [500])
        #expect(library.matching(tmdbID: 693134).isEmpty)
        let state = await store.snapshot
        #expect(state.pending.isEmpty)
        #expect(state.badReleases == [hashA, release.link.lowercased()])
        // The title offers another version.
        #expect(monitor.latest(tmdbID: 693134)?.phase == .failed(message: DownloadCheck.fakeMessage))

        await monitor.pollOnce()
        #expect(events.count == 1)
    }

    /// put.io can list a folder before its video is in it: no video counts only after the usual wait.
    @Test func finishedDownloadWithNoVideoIsRemovedAfterTheWait() async throws {
        let (putio, store, _, monitor) = rig()
        var events: [TransferEvent] = []
        monitor.onEvent = { events.append($0) }
        let tracked = try await monitor.send(makeRelease("a", seeders: 10, name: "Movie.2025.2160p"), target: target)
        monitor.stop()
        putio.add(PutioFile(id: 600, name: "Movie.2025.2160p", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 601, name: "Movie.2025.2160p.zip", fileType: "ARCHIVE", size: 20_000_000), to: 600)
        putio.add(PutioFile(id: 602, name: "READ ME.txt", fileType: "TEXT", size: 300), to: 600)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", hash: hashA, fileId: 600))
        await monitor.pollOnce()
        #expect(events.isEmpty)
        #expect(putio.deleted.isEmpty)
        clock.advance(TransferMonitor.fileGrace + 1)
        await monitor.pollOnce()
        guard case let .failed(item) = events.first else { Issue.record("expected failed"); return }
        #expect(item.phase == .failed(message: DownloadCheck.fakeMessage))
        #expect(putio.deleted == [600])
        #expect(await store.snapshot.badReleases.contains(hashA))
    }

    @Test func singleProgramFileIsRemoved() async throws {
        let (putio, _, _, monitor) = rig()
        let tracked = try await monitor.send(makeRelease("a", seeders: 10, name: "setup.exe"), target: target)
        monitor.stop()
        putio.add(PutioFile(id: 700, name: "setup.exe", fileType: "FILE", size: 3_000_000), to: 0)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", fileId: 700))
        await monitor.pollOnce()
        #expect(putio.deleted == [700])
        #expect(monitor.tracked.first?.phase == .failed(message: DownloadCheck.fakeMessage))
    }

    @Test func realDownloadsAndEmptyListingsAreLeftAlone() async throws {
        let (putio, _, _, monitor) = rig()
        var events: [TransferEvent] = []
        monitor.onEvent = { events.append($0) }
        // put.io hasn't listed the files yet: wait, as before, rather than call it fake.
        let tracked = try await monitor.send(makeRelease("a", seeders: 10, name: "Dune.2024.1080p"), target: target)
        monitor.stop()
        putio.add(PutioFile(id: 800, name: "Dune", fileType: "FOLDER"), to: 0)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", fileId: 800))
        await monitor.pollOnce()
        #expect(events.isEmpty)
        #expect(putio.deleted.isEmpty)
        // Then the video shows up (with the usual extras).
        putio.add(PutioFile(id: 801, name: "Dune.mkv", fileType: "VIDEO", size: 2_000_000_000), to: 800)
        putio.add(PutioFile(id: 802, name: "RARBG.txt", fileType: "TEXT", size: 30), to: 800)
        await monitor.pollOnce()
        guard case let .ready(done) = events.first else { Issue.record("expected ready, got \(events)"); return }
        #expect(done.playableFile?.id == 801)
        #expect(putio.deleted.isEmpty)
    }

    @Test func verdicts() {
        func file(_ name: String, _ type: String = "FILE") -> PutioFile { PutioFile(id: 1, name: name, fileType: type) }
        #expect(DownloadCheck.verdict([]) == .unknown)
        #expect(DownloadCheck.verdict([file("a.mkv", "VIDEO"), file("a.nfo")]) == .video)
        #expect(DownloadCheck.verdict([file("Dune.2024.UHD.BluRay.iso")]) == .video)
        #expect(DownloadCheck.verdict([file("a.mp4", "VIDEO"), file("player.exe")]) == .program("player.exe"))
        #expect(DownloadCheck.verdict([file("a.rar"), file("a.r00")]) == .noVideo)
        #expect(DownloadCheck.badReleaseKeys(hash: " ABC ", link: nil) == ["abc"])
    }

    @Test func oldStateFilesLoadWithoutTheMemory() throws {
        let state = try JSONDecoder().decode(LocalState.self, from: Data(#"{"recentSearches":["x"]}"#.utf8))
        #expect(state.badReleases.isEmpty)
        let pending = try JSONDecoder().decode(PendingTransfer.self, from: Data(#"""
        {"transferID":1,"tmdbID":2,"kind":"movie","title":"X","season":null,"episode":null,"createdAt":0}
        """#.utf8))
        #expect(pending.link == nil)
    }
}

@MainActor @Suite struct SafeSmartGetTests {
    var target: TransferTarget {
        TransferTarget(tmdbID: 1, kind: .movie, title: "X", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
    }

    @Test func skipsAPickWhoseFilesLookFake() async {
        let best = makeRelease("c", seeders: 600, name: "X.2024.1080p.WEB")
        let next = makeRelease("a", seeders: 50, name: "X.2024.1080p.BluRay")
        let picked = await SmartPicker.pickChecked([best, next], rule: .recommended) { release in
            release.id == best.id ? .containsProgram("codec.exe") : nil
        }
        #expect(picked?.id == next.id)
        let none = await SmartPicker.pickChecked([best], rule: .recommended) { _ in .notVideo(largest: "x.zip") }
        #expect(none == nil)
    }

    @Test func neverPicksDiscImages() {
        let iso = makeRelease("c", seeders: 600, name: "X.2024.1080p.BluRay.iso")
        let mkv = makeRelease("a", seeders: 5, name: "X.2024.1080p.BluRay")
        #expect(SmartPicker.pick([iso, mkv], rule: .recommended)?.id == mkv.id)
    }

    @Test func smartGetNeverSendsARememberedFake() async {
        var done = ReleaseSnapshot()
        let bad = makeRelease("c", seeders: 600, name: "X.2024.1080p.WEB")
        let good = makeRelease("a", seeders: 5, name: "X.2024.1080p.WEB")
        done.releases = [bad, good]
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        await store.update { $0.badReleases = [String(repeating: "c", count: 40)] }
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in FakeCatalog() }, makeProvider: { _, _ in nil })
        let model = AppModel(tokens: InMemoryTokenStore([.putio: "p", .tmdb: "t"]), defaults: testDefaults(),
                             store: store, factory: factory)
        model.overrideReleaseSearcher(FakeSearcher(snapshots: [done]))
        let result = await model.smartGet(.movie(imdbID: "tt1", title: "X", year: 2024), target: target)
        model.transfers.stop()
        guard case let .sent(release) = result else { Issue.record("expected sent, got \(result)"); return }
        #expect(release.id == good.id)
        #expect(putio.added.map(\.url) == [good.link])
    }
}
