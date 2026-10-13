import Foundation
import Testing
@testable import AMDBCore

@Suite struct TraktClientTests {
    static let json = #"""
    [{"rank":1,"id":101,"listed_at":"2026-01-01T00:00:00.000Z","notes":null,"type":"movie",
      "movie":{"title":"The Shawshank Redemption","year":1994,"ids":{"trakt":234,"slug":"the-shawshank-redemption-1994","imdb":"tt0111161","tmdb":278}}},
     {"rank":2,"id":102,"type":"show",
      "show":{"title":"Breaking Bad","year":2008,"ids":{"trakt":1388,"imdb":"tt0903747","tmdb":1396}}},
     {"rank":3,"id":103,"type":"person","person":{"name":"Someone"}}]
    """#

    @Test func decodesRankedEntriesWithHeaders() async throws {
        let stub = StubTransport(json: Self.json)
        let entries = try await TraktClient(clientID: "CID", transport: stub)
            .listItems(user: "justin", list: "imdb-top-rated-movies")
        #expect(entries == [
            ChartEntry(rank: 1, kind: .movie, title: "The Shawshank Redemption", year: 1994, imdbID: "tt0111161", tmdbID: 278),
            ChartEntry(rank: 2, kind: .tv, title: "Breaking Bad", year: 2008, imdbID: "tt0903747", tmdbID: 1396),
        ])
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/users/justin/lists/imdb-top-rated-movies/items")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "CID")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
    }

    @Test func chartListsAreKnown() {
        #expect(IMDbChart.top250Movies.list == "imdb-top-rated-movies")
        #expect(IMDbChart.top250TV.list == "imdb-top-rated-tv-shows")
        #expect(IMDbChart.top250TV.kind == .tv)
    }
}
