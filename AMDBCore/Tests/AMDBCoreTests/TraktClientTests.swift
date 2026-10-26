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
        #expect(request.queryItems["limit"] == "250")
        #expect(request.queryItems["page"] == "1")
        #expect(stub.requests.count == 1)
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "CID")
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
    }

    @Test func ratingByIMDbID() async throws {
        let stub = StubTransport(json: #"{"rating":9.3174,"votes":74145,"distribution":{"10":47301}}"#)
        let rating = try await TraktClient(clientID: "CID", transport: stub).rating(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(rating == 9.3)
        #expect(stub.requests.map(\.url?.path) == ["/shows/tt0903747/ratings"])
        #expect(stub.requests.first?.value(forHTTPHeaderField: "trakt-api-key") == "CID")
    }

    @Test func ratingWithoutIMDbIDFindsTraktIDFromTMDB() async throws {
        let stub = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/search/") {
                return (200, Data(#"""
                [{"show":{"ids":{"imdb":null,"slug":"monster-the-ed-gein-story","tmdb":286801,"trakt":279819},
                  "year":2025,"title":"Monster: The Ed Gein Story"},"type":"show","score":100}]
                """#.utf8))
            }
            return (200, Data(#"{"rating":7.04,"votes":900}"#.utf8))
        }
        let rating = try await TraktClient(clientID: "CID", transport: stub).rating(imdbID: nil, tmdbID: 286801, kind: .tv)
        #expect(rating == 7.0)
        #expect(stub.requests.map(\.url?.path) == ["/search/tmdb/286801", "/shows/279819/ratings"])
        #expect(stub.requests.first?.queryItems["type"] == "show")
    }

    /// Trakt answers an IMDb id it doesn't know with 204 and no body; the TMDB id is tried next.
    @Test func unknownIMDbIDFallsBackToTMDB() async throws {
        let stub = StubTransport { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/search/") { return (200, Data(#"[{"type":"show","show":{"ids":{"trakt":1388}}}]"#.utf8)) }
            if path == "/shows/1388/ratings" { return (200, Data(#"{"rating":9.3174,"votes":74145}"#.utf8)) }
            return (204, Data())
        }
        let rating = try await TraktClient(clientID: "CID", transport: stub).rating(imdbID: "tt0000000999", tmdbID: 1396, kind: .tv)
        #expect(rating == 9.3)
        #expect(stub.requests.map(\.url?.path) == ["/shows/tt0000000999/ratings", "/search/tmdb/1396", "/shows/1388/ratings"])
    }

    @Test func unratedOrUnknownIsNil() async throws {
        let unrated = StubTransport(json: #"{"rating":0,"votes":0}"#)
        #expect(try await TraktClient(clientID: "CID", transport: unrated).rating(imdbID: "tt1", tmdbID: nil, kind: .movie) == nil)
        let unknown = StubTransport(json: "[]")
        #expect(try await TraktClient(clientID: "CID", transport: unknown).rating(imdbID: nil, tmdbID: 5, kind: .movie) == nil)
        #expect(unknown.requests.first?.queryItems["type"] == "movie")
    }

    @Test func chartListsAreKnown() {
        #expect(IMDbChart.top250Movies.list == "imdb-top-rated-movies")
        #expect(IMDbChart.top250TV.list == "imdb-top-rated-tv-shows")
        #expect(IMDbChart.top250TV.kind == .tv)
    }

    @Test func followsPagesUntilShortPage() async throws {
        @Sendable func page(_ start: Int, _ count: Int) -> Data {
            let items = (start..<start + count).map {
                #"{"rank":\#($0),"type":"movie","movie":{"title":"T\#($0)","year":2000,"ids":{"imdb":"tt\#($0)","tmdb":\#($0)}}}"#
            }
            return Data("[\(items.joined(separator: ","))]".utf8)
        }
        let stub = StubTransport { request in
            request.queryItems["page"] == "1" ? (200, page(1, 250)) : (200, page(251, 3))
        }
        let entries = try await TraktClient(clientID: "CID", transport: stub).listItems(user: "u", list: "l")
        #expect(entries.count == 253)
        #expect(entries.last?.rank == 253)
        #expect(stub.requests.count == 2)
    }

    @Test func boxOfficeIsRankedWithWeekendGross() async throws {
        let json = #"[{"revenue":42100000,"movie":{"title":"Toy Story 5","year":2026,"ids":{"trakt":1,"imdb":"tt1","tmdb":9}}},{"revenue":950000,"movie":{"title":"Small","year":2026,"ids":{}}}]"#
        let stub = StubTransport(json: json)
        let chart = try await TraktClient(clientID: "c", transport: stub).boxOffice()
        #expect(chart.map(\.rank) == [1, 2])
        #expect(chart[0].tmdbID == 9)
        #expect(chart[0].revenueText == "$42.1M")
        #expect(chart[1].revenueText == "$950K")
        #expect(stub.requests.first?.url?.path == "/movies/boxoffice")
    }
}
