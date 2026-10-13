import Foundation
import Testing
@testable import AMDBCore

@Suite struct YTSProviderTests {
    static let json = #"""
    {"status":"ok","data":{"movie_count":1,"movies":[{"title":"Furiosa: A Mad Max Saga","year":2024,"imdb_code":"tt12037194",
      "torrents":[
        {"hash":"0123456789ABCDEF0123456789ABCDEF01234567","quality":"1080p","type":"web","video_codec":"x264","seeds":1200,"peers":80,"size_bytes":3114029957},
        {"hash":"89ABCDEF0123456789ABCDEF0123456789ABCDEF","quality":"2160p","type":"bluray","video_codec":"x265","seeds":300,"peers":20,"size_bytes":9000000000}
      ]}]}}
    """#

    @Test func mapsTorrentsToReleases() async throws {
        let stub = StubTransport(json: Self.json)
        let provider = YTSProvider(transport: stub)
        let releases = try await provider.releases(for: .movie(imdbID: "tt12037194", title: "Furiosa", year: 2024))

        #expect(releases.count == 2)
        let first = releases[0]
        #expect(first.infoHash == "0123456789abcdef0123456789abcdef01234567")
        #expect(first.link.hasPrefix("magnet:?xt=urn:btih:0123456789abcdef"))
        #expect(first.seeders == 1200)
        #expect(first.sizeBytes == 3_114_029_957)
        #expect(first.sources == [SourceTag(.direct, "YTS")])
        #expect(first.parsed.resolution == .fhd1080)
        #expect(first.parsed.codec == "H.264")
        #expect(releases[1].parsed.resolution == .uhd2160)
        #expect(releases[1].parsed.codec == "H.265")
        #expect(releases[1].parsed.source == "BluRay")

        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/api/v2/list_movies.json")
        #expect(request.queryItems["query_term"] == "tt12037194")
    }

    @Test func ignoresNonMovieQueries() async throws {
        let stub = StubTransport(json: Self.json)
        let releases = try await YTSProvider(transport: stub).releases(for: .text("furiosa"))
        #expect(releases.isEmpty)
        #expect(stub.requests.isEmpty)
    }

    @Test func emptyDataIsEmpty() async throws {
        let stub = StubTransport(json: #"{"status":"ok","data":{"movie_count":0}}"#)
        let releases = try await YTSProvider(transport: stub).releases(for: .movie(imdbID: "tt0", title: "X", year: nil))
        #expect(releases.isEmpty)
    }

    @Test func relevanceRules() {
        var p = ParsedRelease()
        p.season = 1; p.episode = 2
        #expect(ReleaseRelevance.matches(p, .episode(imdbID: "", title: "", season: 1, episode: 2)))
        #expect(!ReleaseRelevance.matches(p, .episode(imdbID: "", title: "", season: 1, episode: 3)))
        #expect(!ReleaseRelevance.matches(p, .season(imdbID: "", title: "", season: 1)))
        #expect(!ReleaseRelevance.matches(p, .movie(imdbID: "", title: "", year: nil)))
        p.episodeEnd = 4
        #expect(ReleaseRelevance.matches(p, .episode(imdbID: "", title: "", season: 1, episode: 3)))
        var movie = ParsedRelease()
        movie.year = 2010
        #expect(!ReleaseRelevance.matches(movie, .movie(imdbID: "", title: "", year: 2024)))
        #expect(ReleaseRelevance.matches(movie, .movie(imdbID: "", title: "", year: 2011)))
        #expect(ReleaseRelevance.matches(movie, .text("anything")))
    }
}
