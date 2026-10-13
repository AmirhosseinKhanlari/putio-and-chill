import Foundation
import Testing
@testable import AMDBCore

@Suite struct EZTVProviderTests {
    static let json = #"""
    {"torrents_count":3,"limit":100,"page":1,"torrents":[
      {"hash":"1111111111111111111111111111111111111111","filename":"a.mkv","title":"Severance S02E04 1080p WEB H264-NTb EZTV","season":"2","episode":"4","seeds":150,"size_bytes":"2147483648","magnet_url":"magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=a"},
      {"hash":"2222222222222222222222222222222222222222","filename":"b.mkv","title":"Severance S02E05 1080p WEB H264-NTb EZTV","season":"2","episode":"5","seeds":90,"size_bytes":"2000000000","magnet_url":"magnet:?xt=urn:btih:2222222222222222222222222222222222222222"},
      {"hash":"3333333333333333333333333333333333333333","filename":"c","title":"Severance S02 1080p WEB H264-NTb","season":"2","episode":"0","seeds":"40","size_bytes":"20000000000","magnet_url":""}
    ]}
    """#

    @Test func filtersEpisode() async throws {
        let stub = StubTransport(json: Self.json)
        let releases = try await EZTVProvider(transport: stub)
            .releases(for: .episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 4))
        #expect(releases.map(\.infoHash) == ["1111111111111111111111111111111111111111"])
        #expect(releases[0].seeders == 150)
        #expect(releases[0].sizeBytes == 2_147_483_648)
        #expect(releases[0].sources == [SourceTag(.direct, "EZTV")])
        #expect(stub.requests.first?.queryItems["imdb_id"] == "11280740")
    }

    @Test func filtersSeasonPackAndBuildsMissingMagnet() async throws {
        let releases = try await EZTVProvider(transport: StubTransport(json: Self.json))
            .releases(for: .season(imdbID: "tt11280740", title: "Severance", season: 2))
        #expect(releases.count == 1)
        #expect(releases[0].seeders == 40)
        #expect(releases[0].link.hasPrefix("magnet:?xt=urn:btih:3333"))
    }

    @Test func ignoresMovies() async throws {
        let stub = StubTransport(json: Self.json)
        #expect(try await EZTVProvider(transport: stub).releases(for: .movie(imdbID: "tt1", title: "x", year: nil)).isEmpty)
        #expect(stub.requests.isEmpty)
    }
}
