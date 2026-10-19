import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct PutioPathsTests {
    @Test func picksLargestNestedVideo() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 500, name: "Release", fileType: "FOLDER"), to: 0)
        putio.add(PutioFile(id: 501, name: "small.mkv", fileType: "VIDEO", size: 10), to: 500)
        putio.add(PutioFile(id: 502, name: "Sub", fileType: "FOLDER"), to: 500)
        putio.add(PutioFile(id: 503, name: "big.mkv", fileType: "VIDEO", size: 900), to: 502)
        putio.add(PutioFile(id: 504, name: "notes.txt", fileType: "TEXT", size: 5000), to: 500)
        #expect(try await PlaybackResolver.playableFile(500, putio: putio)?.id == 503)
    }

    @Test func videoResolvesToItself() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 7, name: "a.mkv", fileType: "VIDEO"), to: 0)
        #expect(try await PlaybackResolver.playableFile(7, putio: putio)?.id == 7)
    }

    @Test func createsMissingFoldersOnceAndCaches() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 3, name: "TV Series", fileType: "FOLDER"), to: 0)
        let store = LocalStore(fileURL: nil)
        let first = try await FolderResolver.folderID(path: ["TV Series", "Severance"], putio: putio, store: store)
        let listsAfterFirst = putio.listCalls
        let second = try await FolderResolver.folderID(path: ["TV Series", "Severance"], putio: putio, store: store)
        #expect(first == second)
        #expect(putio.createdFolders == ["Severance"])
        #expect(putio.listCalls == listsAfterFirst)
        await FolderResolver.forget(path: ["TV Series", "Severance"], store: store)
        #expect(await store.snapshot.folderIDs.isEmpty)
    }

    /// Movies and TV Series sit at the top of put.io; ones the user made with other capitals are found, not doubled.
    @Test func defaultFoldersAreFoundIgnoringCase() async throws {
        let putio = FakePutio()
        putio.add(PutioFile(id: 3, name: "tv series ", fileType: "FOLDER", parentId: 0), to: 0)
        putio.add(PutioFile(id: 4, name: "MOVIES", fileType: "FOLDER", parentId: 0), to: 0)
        let store = LocalStore(fileURL: nil)
        let layout = FolderLayout.standard
        let season = try await layout.destinationID(kind: .tv, title: "Severance", season: 2, putio: putio, store: store)
        let movies = try await layout.destinationID(kind: .movie, title: "Dune", season: nil, putio: putio, store: store)
        #expect(movies == 4)
        #expect(putio.createdFolders == ["Severance", "Season 2"])
        let show = try #require(try await putio.file(id: season).parentId)
        #expect(try await putio.file(id: show).parentId == 3, "inside the existing \"tv series \" folder")
        let tree = FolderTree(folders: try await putio.listFiles(parentID: 0).files)
        #expect(tree.resolve(["TV Series"], under: 0) == 3)
    }

    @Test func defaultDestinations() {
        let layout = FolderLayout.standard
        #expect(layout.displayPath(kind: .movie, title: "Dune", season: nil) == "Movies")
        #expect(layout.displayPath(kind: .tv, title: "Severance", season: 2) == "TV Series/Severance/Season 2")
        let flat = FolderLayout(movies: nil, tv: nil, seasonFolders: false)
        #expect(flat.displayPath(kind: .tv, title: "Severance", season: 2) == "TV Series/Severance")
        let picked = FolderLayout(movies: PutioFolderRef(id: 11, path: "Media/Films"), tv: PutioFolderRef(id: 22, path: "Media/Shows"),
                                  seasonFolders: true)
        #expect(picked.displayPath(kind: .movie, title: "Dune", season: nil) == "Media/Films")
        #expect(picked.displayPath(kind: .tv, title: "Severance", season: 2) == "Media/Shows/Severance/Season 2")
    }

    /// A folder picked in Settings that is the old AMDB/Movies or AMDB/TV (by path, or by a known id) goes back to the
    /// default; other picks stay.
    @Test func oldFolderPicksGoBackToTheDefaults() {
        var settings = AppSettings.defaults
        settings.moviesFolder = PutioFolderRef(id: 5, path: "AMDB/Movies")
        settings.tvFolder = PutioFolderRef(id: 6, path: "amdb/TV ")
        let cleared = settings.withoutOldFolderPicks()
        #expect(cleared.moviesFolder == nil)
        #expect(cleared.tvFolder == nil)

        settings.moviesFolder = PutioFolderRef(id: 5, path: "Renamed/Elsewhere")
        settings.tvFolder = PutioFolderRef(id: 22, path: "Media/Shows")
        let byID = settings.withoutOldFolderPicks(oldIDs: [5])
        #expect(byID.moviesFolder == nil)
        #expect(byID.tvFolder == PutioFolderRef(id: 22, path: "Media/Shows"))

        settings.moviesFolder = PutioFolderRef(id: 7, path: "AMDB/Movies/4K")
        #expect(settings.withoutOldFolderPicks().moviesFolder?.id == 7, "a folder inside the old one isn't the old one")
    }

    /// Saved settings with an old pick are cleaned when the app starts.
    @MainActor @Test func appModelDropsOldPicksAtLaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "old-picks-\(UUID().uuidString)"))
        var saved = AppSettings.defaults
        saved.tvFolder = PutioFolderRef(id: 6, path: "AMDB/TV")
        saved.moviesFolder = PutioFolderRef(id: 50, path: "Films")
        saved.save(to: defaults)
        let model = AppModel(tokens: InMemoryTokenStore([:]), defaults: defaults, store: LocalStore(fileURL: nil))
        #expect(model.settings.tvFolder == nil)
        #expect(model.settings.moviesFolder?.id == 50)
        #expect(AppSettings.load(from: defaults).tvFolder == nil)
    }
}
