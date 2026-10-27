import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// My List on two devices signed in to the same iCloud: one synced Keychain item (`InMemoryWatchLogStore` here).
@MainActor @Suite struct MyListSyncTests {
    let synced = InMemoryWatchLogStore()

    func device(_ clock: Clock) -> MyList {
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        return MyList(store: LocalStore(fileURL: url), synced: synced, now: { clock.now })
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func tick() { now += 60 }
    }

    @Test func savedOnOneDeviceShowsOnTheOther() async {
        let clock = Clock()
        let iPhone = device(clock), tv = device(clock)
        await iPhone.load()
        await tv.load()
        await iPhone.toggle(movie(1, "Dune"))
        clock.tick()
        await iPhone.toggle(show(2, "Severance"))
        await tv.sync()
        #expect(tv.items.map(\.title) == ["Severance", "Dune"])
    }

    @Test func removedOnOneDeviceStaysRemovedEverywhere() async {
        let clock = Clock()
        let iPhone = device(clock), tv = device(clock)
        await iPhone.load()
        await iPhone.toggle(movie(1, "Dune"))
        await tv.load()
        #expect(tv.contains(movie(1, "Dune")))
        clock.tick()
        await tv.toggle(movie(1, "Dune"))
        await iPhone.sync()
        #expect(iPhone.items.isEmpty)
        // The iPhone writing again (another save) doesn't bring it back.
        clock.tick()
        await iPhone.toggle(movie(3, "Arrival"))
        await tv.sync()
        #expect(tv.items.map(\.title) == ["Arrival"])
    }

    /// Lists saved before syncing existed are merged, not replaced; a newer removal still wins over them.
    @Test func listsFromBeforeSyncAreMerged() async {
        let clock = Clock()
        let iPhoneStore = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        let old = MyList(store: LocalStore(fileURL: iPhoneStore))
        await old.load()
        await old.toggle(movie(1, "Dune"))
        await old.toggle(movie(4, "Heat"))
        let tv = device(clock)
        await tv.load()
        await tv.toggle(show(2, "Severance"))

        let iPhone = MyList(store: LocalStore(fileURL: iPhoneStore), synced: synced, now: { clock.now })
        await iPhone.load()
        #expect(Set(iPhone.items.map(\.title)) == ["Dune", "Heat", "Severance"])
        #expect(iPhone.items.map(\.title).filter { $0 != "Severance" } == ["Heat", "Dune"])
        clock.tick()
        await tv.sync()
        await tv.toggle(movie(1, "Dune"))
        await iPhone.sync()
        #expect(Set(iPhone.items.map(\.title)) == ["Heat", "Severance"])
    }

    /// What other devices saved is kept on this device too (Make Room reads the local copy).
    @Test func syncedListIsSavedLocally() async {
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        let store = LocalStore(fileURL: url)
        let tv = MyList(store: store, synced: synced, now: { clock.now })
        await device(clock).toggle(movie(1, "Dune"))
        await tv.load()
        #expect(await store.snapshot.myList.map(\.tmdbID) == [1])
    }

    @Test func oldRemovalsAreForgotten() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = MyListChange(title: SavedTitle(movie(1, "Dune")), at: now - 86_400, removed: true)
        let old = MyListChange(title: SavedTitle(movie(2, "Heat")), at: now - 91 * 86_400, removed: true)
        let saved = MyListChange(title: SavedTitle(movie(3, "Arrival")), at: now - 400 * 86_400, removed: false)
        #expect(MyListLog.merged([kept, old, saved], [], now: now).map(\.title.tmdbID) == [1, 3])
    }

    @Test func noSyncStoreKeepsTheListOnThisDevice() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        let list = MyList(store: LocalStore(fileURL: url))
        await list.toggle(movie(1, "Dune"))
        await list.sync()
        #expect(list.items.map(\.title) == ["Dune"])
        #expect(synced.read(account: MyListLog.account) == nil)
    }
}
