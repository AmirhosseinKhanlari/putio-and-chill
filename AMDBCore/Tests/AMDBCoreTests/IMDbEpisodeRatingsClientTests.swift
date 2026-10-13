import Foundation
import Testing
@testable import AMDBCore

@Suite struct IMDbEpisodeRatingsClientTests {
    @Test func mapsEpisodeNumbersToRatings() async throws {
        let json = #"""
        {"data":{"title":{"episodes":{"episodes":{"edges":[
          {"node":{"series":{"displayableEpisodeNumber":{"episodeNumber":{"text":"1"}}},"ratingsSummary":{"aggregateRating":8.6,"voteCount":53567}}},
          {"node":{"series":{"displayableEpisodeNumber":{"episodeNumber":{"text":"2"}}},"ratingsSummary":{"aggregateRating":null,"voteCount":0}}},
          {"node":{"series":{"displayableEpisodeNumber":{"episodeNumber":{"text":"unknown"}}},"ratingsSummary":{"aggregateRating":7.0,"voteCount":5}}},
          {"node":{"series":{"displayableEpisodeNumber":{"episodeNumber":{"text":"3"}}},"ratingsSummary":{"aggregateRating":9.1,"voteCount":12}}}
        ]}}}}}
        """#
        let stub = StubTransport(json: json)
        let ratings = try await IMDbEpisodeRatingsClient(transport: stub).ratings(seriesIMDbID: "tt0903747", season: 2)
        #expect(ratings == [1: EpisodeRating(rating: 8.6, votes: 53567), 3: EpisodeRating(rating: 9.1, votes: 12)])
        let body = try #require(stub.requests.first).bodyString
        #expect(body.contains("tt0903747"))
        #expect(body.contains(#"includeSeasons: [\"2\"]"#))
    }

    @Test func missingTitleIsEmpty() async throws {
        let ratings = try await IMDbEpisodeRatingsClient(transport: StubTransport(json: #"{"data":{"title":null}}"#))
            .ratings(seriesIMDbID: "tt1", season: 1)
        #expect(ratings.isEmpty)
    }
}
