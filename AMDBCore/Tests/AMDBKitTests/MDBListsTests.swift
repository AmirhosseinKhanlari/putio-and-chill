import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct MDBListsTests {
    /// Counts calls; list 7 has 130 rows, the adult/no-TMDB ones already left out by the client (as `MDBListClient` does).
    final class FakeLists: ListsService, @unchecked Sendable {
        let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        var lists: [MDBList] = []
        var fails = false

        func record(_ call: String) throws {
            lock.withLock { _calls.append(call) }
            if fails { throw AppError.transport("offline") }
        }
        func chart(_ chart: MDBListChart, kind: MediaKind) async throws -> [MDBListTitle] {
            try record("chart \(chart.rawValue) \(kind.rawValue)")
            return [MDBListTitle(tmdbID: 1, kind: kind, title: "\(chart.title) #1", rank: 1, rankChange: 2)]
        }
        func popularLists() async throws -> [MDBList] { try record("popular"); return lists }
        func curatedLists() async throws -> [MDBList] { try record("curated"); return lists }
        func items(of list: Int, offset: Int, limit: Int) async throws -> MDBListPage {
            try record("items \(list) \(offset)")
            let rows = max(0, min(limit, 130 - offset))
            // Every tenth row was an adult title the client dropped.
            let titles = (offset..<offset + rows).filter { $0 % 10 != 9 }.map { MDBListTitle(tmdbID: $0, kind: .movie, title: "T\($0)") }
            return MDBListPage(titles: titles, hasMore: rows >= limit)
        }
    }

    @Test func chartsAreKeptForAWhile() async {
        let fake = FakeLists()
        let lists = MDBLists(maxAge: 3600)
        lists.use(fake)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await lists.loadRows(kind: .movie, now: now)
        #expect(lists.titles(.streamingTop10, .movie).first?.rankChange == 2)
        #expect(lists.titles(.trending, .tv).isEmpty)
        await lists.loadRows(kind: .movie, now: now + 60)
        #expect(fake.calls.count == 3)
        await lists.loadRows(kind: .movie, now: now + 3601)
        #expect(fake.calls.count == 6)
    }

    @Test func listsForATabAndRipListsLeftOutWhenAsked() async {
        let fake = FakeLists()
        fake.lists = [MDBList(id: 1, name: "Netflix Shows", owner: "gary", kind: .tv, count: 300),
                      MDBList(id: 2, name: "Latest 4K REMUX Releases", owner: "barr2", kind: nil, count: 337),
                      MDBList(id: 3, name: "Christmas Movies", owner: "jb", kind: .movie, count: 1544),
                      MDBList(id: 4, name: "Empty", owner: "x", kind: nil, count: 0)]
        let full = MDBLists()
        full.use(fake)
        await full.loadLists()
        #expect(full.lists(for: .tv).popular.map(\.id) == [1, 2])
        #expect(full.lists(for: .movie).curated.map(\.id) == [2, 3])
        let store = MDBLists(hidesRipLists: true)
        store.use(fake)
        await store.loadLists()
        #expect(store.lists(for: .movie).popular.map(\.id) == [3])
    }

    @Test func ripListNames() {
        for name in ["Latest 4K REMUX Releases", "Dolby Vision P7-FEL", "Latest Blu-ray Releases", "Best WEB-DL"] {
            #expect(MDBLists.isAboutRips(name), "\(name)")
        }
        for name in ["Netflix Shows", "Ripley", "Felicity", "Christmas Movies", "Latest 4K Movies"] {
            #expect(!MDBLists.isAboutRips(name), "\(name)")
        }
    }

    @Test func failureIsSaidAndTriedAgain() async {
        let fake = FakeLists()
        fake.fails = true
        let lists = MDBLists()
        lists.use(fake)
        await lists.loadLists()
        #expect(lists.listsFailed)
        fake.fails = false
        fake.lists = [MDBList(id: 1, name: "Netflix Shows", owner: "gary", kind: .tv, count: 300)]
        await lists.loadLists()
        #expect(!lists.listsFailed && lists.popular.count == 1)
    }

    @Test func noKeyMeansNothing() async {
        let lists = MDBLists()
        lists.use(FakeLists())
        await lists.loadRows(kind: .tv)
        #expect(lists.isAvailable && !lists.charts.isEmpty)
        lists.use(nil)
        #expect(!lists.isAvailable && lists.charts.isEmpty)
    }

    /// Pages follow MDBList's rows, so titles the client left out don't make a page start early or repeat.
    @Test func listPagesFollowMDBListsRows() async {
        let fake = FakeLists()
        let lists = MDBLists()
        lists.use(fake)
        let model = MDBListModel(list: MDBList(id: 7, name: "L", owner: "o", kind: nil, count: 130), lists: lists)
        await model.loadMore()
        await model.loadMore()
        await model.loadMore()
        await model.loadMore()
        #expect(fake.calls == ["items 7 0", "items 7 60", "items 7 120"])
        #expect(!model.hasMore)
        #expect(model.titles.count == 117)
        #expect(Set(model.titles.map(\.id)).count == 117)
    }
}
