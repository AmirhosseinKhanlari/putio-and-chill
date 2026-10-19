import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// What the library reads: Movies and TV Series (any depth), loose videos at the top, and folders picked in Settings.
@MainActor @Suite struct LibraryScopeTests {
    static func folder(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "FOLDER", parentId: parent)
    }

    static func video(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "VIDEO", size: 2_000_000_000, parentId: parent, createdAt: "2026-10-\(10 + id % 10)")
    }

    static func world() -> FakePutio {
        let putio = FakePutio()
        let files: [PutioFile] = [
            video(1, "Loose.Movie.2020.mkv", in: 0),
            PutioFile(id: 2, name: "notes.txt", fileType: "TEXT", parentId: 0),
            folder(10, "MOVIES", in: 0), folder(11, "Dune.2021.1080p", in: 10), video(111, "Dune.2021.1080p.mkv", in: 11),
            folder(12, "Subs", in: 11), video(121, "never.read.mkv", in: 12),
            folder(20, " tv series", in: 0), folder(21, "Severance", in: 20), folder(22, "Season 2", in: 21),
            video(221, "Severance.S02E04.mkv", in: 22),
            folder(30, "Downloads", in: 0), video(301, "Other.2019.mkv", in: 30),
            folder(40, "AMDB", in: 0), folder(41, "TV", in: 40), video(411, "Old.S01E01.mkv", in: 41),
            folder(50, "Media", in: 0), folder(51, "Films", in: 50), video(511, "Picked.2022.mkv", in: 51),
        ]
        for file in files { putio.add(file, to: file.parentId ?? 0) }
        return putio
    }

    @Test func readsMoviesTVSeriesAndLooseTopLevelVideos() async throws {
        let putio = Self.world()
        var folders: [PutioFile] = []
        let found = try await LibraryIndex.walk(putio, maxFolders: 2000) { folders.append($0) }
        #expect(Set(found.map(\.file.id)) == [1, 111, 221], "not Downloads, AMDB or Media; not Subs")
        #expect(found.first { $0.file.id == 221 }?.folder == "Season 2")
        // Other top-level folders are known (Movies / TV Series are found by name) but not opened.
        #expect(Set(folders.map(\.id)).isSuperset(of: [10, 20, 30, 40, 50]))
        #expect(!folders.contains { $0.id == 41 || $0.id == 51 })
    }

    @Test func foldersPickedInSettingsAreReadToo() async throws {
        let putio = Self.world()
        let layout = FolderLayout(movies: PutioFolderRef(id: 51, path: "Media/Films"),
                                  tv: PutioFolderRef(id: 999, path: "Gone/Shows"), seasonFolders: true)
        let found = try await LibraryIndex.walk(putio, scope: LibraryScope(layout: layout), maxFolders: 2000)
        #expect(Set(found.map(\.file.id)) == [1, 111, 221, 511], "a picked folder that's gone is skipped, not an error")
        #expect(found.first { $0.file.id == 511 }?.folder == "Films")
    }

    @Test func aFolderPickedInsideMoviesIsReadOnce() async throws {
        let putio = Self.world()
        let scope = LibraryScope(layout: FolderLayout(movies: PutioFolderRef(id: 11, path: "Movies/Dune.2021.1080p"), tv: nil,
                                                      seasonFolders: true))
        let found = try await LibraryIndex.walk(putio, scope: scope, maxFolders: 2000)
        #expect(found.filter { $0.file.id == 111 }.count == 1)
    }

    @Test func topLevelFolderNamesIgnoreCase() {
        let scope = LibraryScope.standard
        #expect(scope.includesTopLevelFolder(Self.folder(1, "movies", in: 0)))
        #expect(scope.includesTopLevelFolder(Self.folder(2, "TV SERIES ", in: 0)))
        #expect(!scope.includesTopLevelFolder(Self.folder(3, "TV", in: 0)))
        #expect(!scope.includesTopLevelFolder(Self.folder(4, "Movies 4K", in: 0)))
    }

    /// No Movies or TV Series yet: just the loose videos.
    @Test func missingFoldersAreJustEmpty() async throws {
        let putio = FakePutio()
        putio.add(Self.video(1, "Loose.Movie.2020.mkv", in: 0), to: 0)
        putio.add(Self.folder(30, "Downloads", in: 0), to: 0)
        putio.add(Self.video(301, "Other.2019.mkv", in: 30), to: 30)
        let found = try await LibraryIndex.walk(putio, maxFolders: 2000)
        #expect(found.map(\.file.id) == [1])
    }

    /// A library cached by an older build (which read everything) is read again at launch, even when it's fresh,
    /// and the files that drop out aren't announced as removed.
    @Test func aCacheFromAnotherScopeIsReadAgain() async {
        let putio = Self.world()
        let cache = LibraryCache(fileURL: nil)
        let old = [301, 411].map { LibraryEntry(file: Self.video(Int64($0), "Old \($0).mkv", in: 30), match: nil, folderName: nil) }
        await cache.save(LibrarySnapshot(entries: old, updatedAt: Date()))
        let library = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        library.configure(putio: putio, catalog: FakeCatalog())
        await library.loadCached()
        #expect(library.needsRescan)
        #expect(library.isStale(maxAge: 3600))
        var changes: [LibraryChange] = []
        library.onUpdated = { changes.append($0) }
        await library.refresh()
        #expect(Set(library.entries.map(\.id)) == [1, 111, 221])
        #expect(changes.first?.rescoped == true)
        #expect(!library.needsRescan)
        #expect(await cache.load()?.scope == LibraryScope.standard.signature)

        // Same scope next launch: the cache is trusted.
        let next = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        next.configure(putio: putio, catalog: FakeCatalog())
        await next.loadCached()
        #expect(!next.needsRescan)
        #expect(!next.isStale(maxAge: 3600))

        // Picking a folder in Settings changes the scope: due again.
        next.scope = LibraryScope(layout: FolderLayout(movies: PutioFolderRef(id: 51, path: "Media/Films"), tv: nil, seasonFolders: true))
        #expect(next.needsRescan)
    }

    /// A video played from Files outside the scope shows in Continue Watching until the next update drops it.
    @Test func playedFromElsewhereStaysUntilTheNextUpdate() async {
        let putio = Self.world()
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: putio, catalog: FakeCatalog())
        await library.refresh()
        let outside = LibraryEntry(file: Self.video(301, "Other.2019.mkv", in: 30), match: nil, folderName: nil)
        library.notePlayed(outside)
        library.noteProgress(fileID: 301, seconds: 600)
        #expect(library.continueWatching.map(\.id) == [301])
        await library.refresh()
        #expect(!library.entries.contains { $0.id == 301 })
        #expect(library.continueWatching.isEmpty)
    }
}
