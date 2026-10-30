import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct LibraryCacheTests {
    func index(_ putio: FakePutio, cache: LibraryCache, store: LocalStore = LocalStore(fileURL: nil)) -> LibraryIndex {
        let index = LibraryIndex(store: store, cache: cache)
        index.configure(putio: putio, catalog: LibraryIndexTests.catalog)
        return index
    }

    @Test func launchShowsCachedLibraryBeforeAnyNetwork() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = index(LibraryIndexTests.tree(), cache: LibraryCache(fileURL: file))
        await first.refresh()
        first.noteProgress(fileID: 11, seconds: 777)
        try await Task.sleep(for: .milliseconds(150))  // the progress save runs in its own task

        // Next launch: a new cache object reading the same file, put.io not even asked.
        let putio = LibraryIndexTests.tree()
        let second = index(putio, cache: LibraryCache(fileURL: file))
        await second.loadCached()
        #expect(second.entries.map(\.id) == [12, 10, 11, 14])
        #expect(second.entries.first { $0.id == 10 }?.match?.tmdbID == 693134)
        #expect(second.lastUpdated != nil)
        #expect(second.resumeSeconds(for: second.entries.first { $0.id == 11 }!) == 777)
        #expect(putio.listCalls == 0)
    }

    @Test func refreshReportsWhatChanged() async {
        let putio = LibraryIndexTests.tree()
        let library = index(putio, cache: LibraryCache(fileURL: nil))
        var changes: [LibraryChange] = []
        library.onUpdated = { changes.append($0) }
        await library.refresh()
        putio.add(PutioFile(id: 20, name: "Heat.1995.2160p.mkv", fileType: "VIDEO", size: 9_000_000_000), to: 0)
        await library.refresh()
        #expect(changes == [LibraryChange(added: 4, removed: 0), LibraryChange(added: 1, removed: 0)])
    }

    @Test func staleness() async {
        let library = index(LibraryIndexTests.tree(), cache: LibraryCache(fileURL: nil))
        #expect(library.isStale(maxAge: 3600))
        await library.refresh()
        #expect(!library.isStale(maxAge: 3600))
        #expect(library.isStale(maxAge: 3600, now: Date().addingTimeInterval(3700)))
    }

    @Test func signingOutForgetsTheCache() async {
        let cache = LibraryCache(fileURL: nil)
        let library = index(LibraryIndexTests.tree(), cache: cache)
        await library.refresh()
        library.configure(putio: nil, catalog: nil)
        #expect(library.entries.isEmpty)
        // The cache is cleared in the background: wait for it (a fixed short wait failed under a busy test run).
        for _ in 0..<200 where await cache.load() != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await cache.load() == nil)
    }

    /// Signing out while an update is still reading put.io: the update's files, positions and date never land, and
    /// nothing is written to the cache file another account would see at its first launch.
    @Test func signingOutDuringAnUpdateLeavesTheLibraryEmpty() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let putio = LibraryIndexTests.tree()
        putio.listDelay = .milliseconds(300)
        let cache = LibraryCache(fileURL: file)
        let library = index(putio, cache: cache)
        let refresh = Task { await library.refresh() }
        for _ in 0..<100 where !library.isRefreshing { try? await Task.sleep(for: .milliseconds(5)) }
        library.configure(putio: nil, catalog: nil)
        await refresh.value
        #expect(library.entries.isEmpty)
        #expect(library.lastUpdated == nil)
        #expect(!library.isRefreshing)
        for _ in 0..<200 where await cache.load() != nil { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await cache.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The same when put.io was already read and the update is matching files to TMDB when the user signs out.
    @Test func signingOutDuringMatchingLeavesTheLibraryEmpty() async {
        var slow = LibraryIndexTests.catalog
        slow.searchDelay = .milliseconds(300)
        let cache = LibraryCache(fileURL: nil)
        let library = LibraryIndex(store: LocalStore(fileURL: nil), cache: cache)
        library.configure(putio: LibraryIndexTests.tree(), catalog: slow)
        let refresh = Task { await library.refresh() }
        for _ in 0..<100 where library.pendingMatches == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        library.configure(putio: nil, catalog: nil)
        await refresh.value
        #expect(library.entries.isEmpty)
        #expect(library.lastUpdated == nil)
        #expect(library.pendingMatches == 0)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await cache.load() == nil)
    }

    /// A position check that put.io answers after the sign-out says nothing about the next account.
    @Test func aPositionCheckEndingAfterSignOutIsDropped() async {
        let putio = LibraryIndexTests.tree()
        let library = index(putio, cache: LibraryCache(fileURL: nil))
        await library.refresh()
        putio.setPosition(2000, fileID: 11)
        putio.startFromDelay = .milliseconds(200)
        let check = Task { await library.checkPositions([11]) }
        try? await Task.sleep(for: .milliseconds(50))
        library.configure(putio: nil, catalog: nil)
        #expect(await check.value.isEmpty)
        #expect(library.positions.isEmpty)
        #expect(library.resumeSeconds(fileID: 11) == 0)
    }

    @Test func autoUpdatePolicy() async {
        let putio = LibraryIndexTests.tree()
        let catalog = LibraryIndexTests.catalog
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in catalog },
                                     makeProvider: { _ in nil })
        let app = AppModel(tokens: InMemoryTokenStore([.putio: "t", .tmdb: "t"]), defaults: testDefaults(),
                           store: LocalStore(fileURL: nil), factory: factory)
        #expect(await app.refreshLibraryIfDue(), "never fetched: always runs")
        #expect(await app.refreshLibraryIfDue() == false, "fresh: skipped")
        #expect(await app.refreshLibraryIfDue(now: Date().addingTimeInterval(61 * 60)), "older than an hour: runs")
        var settings = app.settings
        settings.libraryAutoUpdate = false
        app.updateSettings(settings)
        #expect(await app.refreshLibraryIfDue(now: Date().addingTimeInterval(10 * 3600)) == false, "auto update off")
        #expect(await app.refreshLibraryIfDue(force: true), "Update now always runs")
    }
}
