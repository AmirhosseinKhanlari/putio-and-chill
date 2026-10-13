import Foundation
import Testing
@testable import AMDBCore

@Suite struct TorrentsCSVProviderTests {
    static let json = #"""
    {"torrents":[
      {"infohash":"89599bf4dc369a3a8eca26411c5ccf922d78b486","name":"Interstellar (2014) (2014) 1080p BrRip x264 - YIFY","size_bytes":2431905867,"created_unix":1426426450,"seeders":1039,"leechers":197,"completed":52511,"id":1151},
      {"infohash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Interstellar.1999.Documentary.720p","size_bytes":700000000,"seeders":3,"leechers":0,"id":7}
    ],"next":1151}
    """#

    @Test func searchesAndFiltersByYear() async throws {
        let stub = StubTransport(json: Self.json)
        let releases = try await TorrentsCSVProvider(transport: stub)
            .releases(for: .movie(imdbID: "tt0816692", title: "Interstellar", year: 2014))
        #expect(releases.count == 1)
        #expect(releases[0].infoHash == "89599bf4dc369a3a8eca26411c5ccf922d78b486")
        #expect(releases[0].seeders == 1039)
        #expect(releases[0].sizeBytes == 2_431_905_867)
        #expect(releases[0].sources == [SourceTag(.direct, "Torrents.csv")])
        #expect(releases[0].link.hasPrefix("magnet:?xt=urn:btih:89599bf4"))
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/service/search")
        #expect(request.queryItems["q"] == "Interstellar 2014")
        #expect(request.queryItems["size"] == "50")
    }

    @Test func emptyResults() async throws {
        let releases = try await TorrentsCSVProvider(transport: StubTransport(json: #"{"torrents":[],"next":null}"#))
            .releases(for: .text("nothing"))
        #expect(releases.isEmpty)
    }
}
