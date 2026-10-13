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
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt0816692", kind: .movie)
        #expect(ratings == Ratings(imdb: 8.7, imdbVotes: 2_300_000, tomatoes: 73, popcorn: 86, metacritic: 74, letterboxd: 4.3))
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/imdb/movie/tt0816692")
        #expect(request.queryItems["apikey"] == "K")
    }

    @Test func showsUseShowPathAndMissingScoresStayNil() async throws {
        let stub = StubTransport(json: #"{"ratings":[{"source":"imdb","value":8.6,"score":86,"votes":1000},{"source":"tomatoes","value":null,"score":null}]}"#)
        let ratings = try await RatingsClient(apiKey: "K", transport: stub).ratings(imdbID: "tt11280740", kind: .tv)
        #expect(ratings.imdb == 8.6)
        #expect(ratings.tomatoes == nil)
        #expect(!ratings.isEmpty)
        #expect(stub.requests.first?.url?.path == "/imdb/show/tt11280740")
    }

    @Test func badKeyIsUnauthorized() async {
        let client = RatingsClient(apiKey: "bad", transport: StubTransport(status: 401, json: #"{"error":"Invalid API key"}"#))
        await #expect(throws: AppError.unauthorized(service: "mdblist")) {
            _ = try await client.ratings(imdbID: "tt1", kind: .movie)
        }
    }

    @Test func emptyRatings() {
        #expect(Ratings().isEmpty)
    }
}
