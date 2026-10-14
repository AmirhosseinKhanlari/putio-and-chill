import Foundation
import Testing
@testable import AMDBCore

@Suite struct IMDbWatchlistClientTests {
    @Test func linksAndIDs() {
        #expect(IMDbListRef.parse("https://www.imdb.com/user/ur197805275/watchlist/?ref_=nv_usr_wl_all_0") == .watchlist(userID: "ur197805275"))
        #expect(IMDbListRef.parse("https://m.imdb.com/user/ur197805275/") == .watchlist(userID: "ur197805275"))
        #expect(IMDbListRef.parse("  ur197805275 ") == .watchlist(userID: "ur197805275"))
        #expect(IMDbListRef.parse("https://www.imdb.com/list/ls591814193/") == .list(id: "ls591814193"))
        #expect(IMDbListRef.parse("https://www.imdb.com/title/tt2692904/") == nil)
        #expect(IMDbListRef.parse("hello") == nil)
    }

    @Test func readsEveryPageInOrder() async throws {
        let first = #"{"data":{"list":{"titleListItemSearch":{"total":3,"pageInfo":{"hasNextPage":true,"endCursor":"abc"},"edges":[{"listItem":{"id":"tt2692904","titleText":{"text":"Locke"},"titleType":{"id":"movie"},"releaseYear":{"year":2013}}},{"listItem":{"id":"tt0903747","titleText":{"text":"Breaking Bad"},"titleType":{"id":"tvSeries"},"releaseYear":{"year":2008}}}]}}}}"#
        let second = #"{"data":{"list":{"titleListItemSearch":{"total":3,"pageInfo":{"hasNextPage":false,"endCursor":null},"edges":[{"listItem":{"id":"tt0044409","titleText":{"text":"Beauties of the Night"},"titleType":{"id":"movie"},"releaseYear":{"year":1952}}}]}}}}"#
        let calls = Counter()
        let stub = StubTransport { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            calls.increment()
            return (200, Data((body.contains("after") ? second : first).utf8))
        }
        let titles = try await IMDbWatchlistClient(transport: stub).titles(.watchlist(userID: "ur1"))
        #expect(titles.map(\.imdbID) == ["tt2692904", "tt0903747", "tt0044409"])
        #expect(titles[1].isShow)
        #expect(!titles[0].isShow)
        #expect(calls.value == 2)
    }

    @Test func aPrivateWatchlistSaysSo() async {
        let stub = StubTransport(json: #"{"data":{"list":null}}"#)
        await #expect(throws: IMDbWatchlistError.privateOrMissing) {
            try await IMDbWatchlistClient(transport: stub).titles(.watchlist(userID: "ur1"))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
