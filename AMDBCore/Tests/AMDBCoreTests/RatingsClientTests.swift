import Foundation
import Testing
@testable import AMDBCore

@Suite struct RatingsClientTests {
    static let json = #"""
    {"title":"Interstellar","year":2014,"type":"movie","ratings":[
      {"source":"imdb","value":8.7,"score":87,"votes":2300000,"url":"https://imdb.com/title/tt0816692"},
      {"source":"metacritic","value":74,"score":74,"votes":null},
      {"source":"tomatoes","value":73,"score":73,"votes":300},
      {"source":"popcorn","value":"86","score":86,"votes":250000},
      {"source":"letterboxd","value":4.3,"score":86,"votes":null},
      {"source":"rogerebert","value":null,"score":null,"votes":null}
    ]}
    """#

    @Test func mapsSourcesAndBuildsRequest() async throws {
        let stub = StubTransport(json: Self.json)
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt0816692", tmdbID: 157336, kind: .movie)
        #expect(ratings == Ratings(imdb: 8.7, imdbVotes: 2_300_000, tomatoes: 73, popcorn: 86, metacritic: 74, letterboxd: 4.3))
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/imdb/movie/tt0816692")
        #expect(request.queryItems["apikey"] == "K")
    }

    @Test func showsUseShowPathAndMissingScoresStayNil() async throws {
        let stub = StubTransport(json: #"{"ratings":[{"source":"imdb","value":8.6,"score":86,"votes":1000},{"source":"tomatoes","value":null,"score":null}]}"#)
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt11280740", tmdbID: 95396, kind: .tv)
        #expect(ratings.imdb == 8.6)
        #expect(ratings.tomatoes == nil)
        #expect(!ratings.isEmpty)
        #expect(stub.requests.first?.url?.path == "/imdb/show/tt11280740")
    }

    @Test func badKeyIsUnauthorized() async {
        let client = RatingsClient(apiKey: "bad", transport: StubTransport(status: 401, json: #"{"error":"Invalid API key"}"#))
        await #expect(throws: AppError.unauthorized(service: "mdblist")) {
            _ = try await client.ratings(imdbID: "tt1", tmdbID: 1, kind: .movie)
        }
    }

    /// MDBList may leave `value` null and send only the 0–100 `score` (and use other source names).
    @Test func readsScoreWhenValueIsMissing() async throws {
        let stub = StubTransport(json: #"""
        {"ratings":[
          {"source":"imdb","value":null,"score":86,"votes":"1200"},
          {"source":"tomatoes","value":null,"score":95.4},
          {"source":"audience","value":null,"score":"90"},
          {"source":"metacritic","value":null,"score":null},
          {"source":"letterboxd","value":null,"score":82},
          {"source":null,"value":5},
          {"source":"trakt","value":93,"score":93}
        ]}
        """#)
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(ratings == Ratings(imdb: 8.6, imdbVotes: 1200, tomatoes: 95, popcorn: 90, letterboxd: 4.1))
        #expect(stub.requests.map(\.url?.path) == ["/imdb/show/tt0903747"])
    }

    @Test func emptyIMDbAnswerFallsBackToTMDB() async throws {
        let stub = StubTransport { request in
            let path = request.url?.path ?? ""
            let body = path.hasPrefix("/imdb/")
                ? #"{"ratings":[{"source":"imdb","value":null,"score":null},{"source":"tomatoes","value":null}]}"#
                : #"{"ratings":[{"source":"imdb","value":9.5,"score":95,"votes":2000000},{"source":"tomatoes","value":96}]}"#
            return (200, Data(body.utf8))
        }
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt0903747", tmdbID: 1396, kind: .tv)
        #expect(ratings.imdb == 9.5)
        #expect(ratings.tomatoes == 96)
        #expect(stub.requests.map(\.url?.path) == ["/imdb/show/tt0903747", "/tmdb/show/1396"])
        #expect(stub.requests.last?.queryItems["apikey"] == "K")
    }

    @Test func notFoundByIMDbFallsBackToTMDB() async throws {
        let stub = StubTransport { request in
            request.url?.path.hasPrefix("/imdb/") == true
                ? (404, Data(#"{"error":"Not found"}"#.utf8))
                : (200, Data(#"{"ratings":[{"source":"imdb","value":7.9}]}"#.utf8))
        }
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt9999999", tmdbID: 42, kind: .movie)
        #expect(ratings.imdb == 7.9)
        #expect(stub.requests.map(\.url?.path) == ["/imdb/movie/tt9999999", "/tmdb/movie/42"])
    }

    @Test func titlesWithoutIMDbIDGoStraightToTMDB() async throws {
        let stub = StubTransport(json: #"{"ratings":[{"source":"imdb","value":7.1}]}"#)
        let client = RatingsClient(apiKey: "K", transport: stub)
        #expect(try await client.ratings(imdbID: nil, tmdbID: 286801, kind: .tv).imdb == 7.1)
        #expect(try await client.ratings(imdbID: " ", tmdbID: 286801, kind: .tv).imdb == 7.1)
        #expect(stub.requests.map(\.url?.path) == ["/tmdb/show/286801", "/tmdb/show/286801"])
    }

    @Test func unknownEverywhereIsEmptyNotAnError() async throws {
        let stub = StubTransport(status: 404, json: #"{"error":"Not found"}"#)
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt1", tmdbID: 2, kind: .tv)
        #expect(ratings.isEmpty)
        #expect(stub.requests.count == 2)
    }

    @Test func mergeFillsGaps() {
        let merged = Ratings(imdb: 8, tomatoes: 90).merged(with: Ratings(imdb: 1, imdbVotes: 5, metacritic: 70, trakt: 8.4))
        #expect(merged == Ratings(imdb: 8, tomatoes: 90, metacritic: 70, trakt: 8.4))
    }

    @Test func emptyRatings() {
        #expect(Ratings().isEmpty)
    }
}
