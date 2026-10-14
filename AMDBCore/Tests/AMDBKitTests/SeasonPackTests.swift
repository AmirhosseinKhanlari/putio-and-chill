import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct SeasonPackTests {
    @Test func episodeNumbersFromPackFileNames() {
        let cases: [(String, Int?, Int?)] = [
            ("Task (2025) - S01E03 - Nobodys Stronger (1080p BluRay x265 10bit EAC3 5.1 Ghost).mkv", 1, 3),
            ("Task.S01E07.1080p.HEVC.x265-MeGusta[EZTVx.to].mkv", 1, 7),
            ("01 - Crossings.mkv", nil, 1),
            ("Episode 4.mkv", nil, 4),
            ("E05.mkv", nil, 5),
            ("Ep 6 - Title.mkv", nil, 6),
            ("1x08 Title.mkv", 1, 8),
        ]
        for (name, season, episode) in cases {
            let found = EpisodeNumbering.episode(in: name)
            #expect(found?.season == season, "\(name)")
            #expect(found?.episode == episode, "\(name)")
        }
        #expect(EpisodeNumbering.episode(in: "Task.2025.1080p.BluRay.x265.mkv") == nil)
        #expect(EpisodeNumbering.episode(in: "Sample.mkv") == nil)
    }

    @Test func repairsOnlyTVMatchesMissingTheEpisode() {
        let seasonOnly = LibraryMatch(tmdbID: 7, mediaType: .tv, season: 1, episode: nil, confidence: 1, title: "Task")
        #expect(EpisodeNumbering.repaired(seasonOnly, fileName: "Task.S01E05.mkv")?.episode == 5)
        let complete = LibraryMatch(tmdbID: 7, mediaType: .tv, season: 1, episode: 2, confidence: 1, title: "Task")
        #expect(EpisodeNumbering.repaired(complete, fileName: "Task.S01E05.mkv") == nil)
        let movie = LibraryMatch(tmdbID: 9, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "Heat")
        #expect(EpisodeNumbering.repaired(movie, fileName: "Heat.1995.mkv") == nil)
    }

    /// A finished season pack puts every episode in the library, and Play starts at episode 1 (not the largest file).
    @Test func finishedSeasonPackRecordsEveryEpisode() async throws {
        let putio = FakePutio()
        let store = LocalStore(fileURL: nil)
        let library = LibraryIndex(store: store)
        library.configure(putio: putio, catalog: FakeCatalog())
        let monitor = TransferMonitor(store: store, pollInterval: .seconds(3600))
        monitor.configure(putio: putio, library: library)
        let target = TransferTarget(tmdbID: 77, kind: .tv, title: "Task", posterPath: "/p.jpg", backdropPath: nil, season: 1, episode: nil)
        let tracked = try await monitor.send(Release(name: "Task.S01.1080p", link: "magnet:?xt=urn:btih:aa", sizeBytes: 1,
                                                     seeders: 5, sources: []), target: target)
        monitor.stop()
        putio.add(PutioFile(id: 600, name: "Task (2025) S01 (1080p BluRay x265 Ghost)", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 601, name: "Task (2025) - S01E01 - Crossings.mkv", fileType: "VIDEO", size: 100), to: 600)
        putio.add(PutioFile(id: 602, name: "Task (2025) - S01E02 - Vigil.mkv", fileType: "VIDEO", size: 900), to: 600)
        putio.add(PutioFile(id: 603, name: "Task (2025) - S01E03 - Nobodys.mkv", fileType: "VIDEO", size: 500), to: 600)
        putio.add(PutioFile(id: 610, name: "Subs", fileType: "FOLDER"), to: 600)
        putio.setTransfer(PutioTransfer(id: tracked.id, status: "COMPLETED", percentDone: 100, fileId: 600))
        await monitor.pollOnce()

        #expect(monitor.tracked.first?.playableFile?.id == 601)
        #expect(library.matching(tmdbID: 77, season: 1).count == 3)
        for episode in 1...3 { #expect(library.matching(tmdbID: 77, season: 1, episode: episode).count == 1) }
        #expect(await store.snapshot.matches[602]?.episode == 2)
    }

    /// What earlier builds saved ("season 1", no episode) is completed on the next refresh; nothing else changes.
    @Test func refreshRepairsOldSeasonOnlyMatches() async {
        let putio = FakePutio()
        putio.add(PutioFile(id: 1, name: "Season 1", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 11, name: "Task.S01E05.1080p.mkv", fileType: "VIDEO", size: 100), to: 1)
        let store = LocalStore(fileURL: nil)
        await store.update { state in
            state.matches[11] = LibraryMatch(tmdbID: 77, mediaType: .tv, season: 1, episode: nil, confidence: 1, title: "Task")
        }
        let library = LibraryIndex(store: store)
        library.configure(putio: putio, catalog: FakeCatalog())
        await library.refresh()
        #expect(library.matching(tmdbID: 77, season: 1, episode: 5).map(\.id) == [11])
        #expect(await store.snapshot.matches[11]?.episode == 5)
        #expect(await store.snapshot.matches[11]?.title == "Task")
    }

    /// Subtitle folders aren't read, and a big put.io is read past the old 300-folder limit.
    @Test func walkSkipsSubtitleFoldersAndReadsDeepPacks() async throws {
        let putio = FakePutio()
        var id: Int64 = 1
        for _ in 0..<400 {
            id += 1
            putio.add(PutioFile(id: id, name: "Old \(id)", fileType: "FOLDER"), to: 0)
        }
        putio.add(PutioFile(id: 9000, name: "Pack", fileType: "FOLDER"), to: id)
        putio.add(PutioFile(id: 9001, name: "Task.S01E01.mkv", fileType: "VIDEO", size: 100), to: 9000)
        putio.add(PutioFile(id: 9002, name: "Subs", fileType: "FOLDER"), to: 9000)
        putio.add(PutioFile(id: 9003, name: "1_English", fileType: "FOLDER"), to: 9002)
        let found = try await LibraryIndex.walk(putio, maxFolders: 2000)
        #expect(found.map(\.file.id) == [9001])
        #expect(putio.listCalls == 402)  // root + 400 folders + the pack; not Subs or its folders
    }

    @Test func downloadsTakeTheRepairedEpisode() async {
        let downloads = DownloadsIndex(store: LocalStore(fileURL: nil))
        await downloads.upsert(DownloadRecord(fileID: 11, title: "Task", posterPath: nil, tmdbID: 77, kind: .tv, season: 1,
                                              episode: nil, state: .done(relativePath: "x")))
        await downloads.upsert(DownloadRecord(fileID: 12, title: "Heat", posterPath: nil, tmdbID: 9, kind: .movie, season: nil,
                                              episode: nil, state: .done(relativePath: "y")))
        let entry = LibraryEntry(file: PutioFile(id: 11, name: "Task.S01E05.mkv", fileType: "VIDEO"),
                                 match: LibraryMatch(tmdbID: 77, mediaType: .tv, season: 1, episode: 5, confidence: 1, title: "Task"),
                                 folderName: nil)
        await downloads.adopt([entry])
        #expect(downloads.record(fileID: 11)?.episode == 5)
        #expect(downloads.record(fileID: 11)?.state == .done(relativePath: "x"))
        #expect(downloads.record(fileID: 12)?.title == "Heat")
    }
}
