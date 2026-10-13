import Foundation
import Testing
@testable import AMDBCore

@Suite struct KnabenProviderTests {
    static let json = #"""
    {"hits":[
      {"title":"Severance.S02E04.1080p.WEB.H264-NTb","hash":"cccccccccccccccccccccccccccccccccccccccc","magnetUrl":null,"link":null,"bytes":2100000000,"seeders":77,"peers":5,"tracker":"1337x"},
      {"title":"Severance.S02E03.1080p.WEB.H264-NTb","hash":"dddddddddddddddddddddddddddddddddddddddd","magnetUrl":"magnet:?xt=urn:btih:dddddddddddddddddddddddddddddddddddddddd","bytes":2000000000,"seeders":60,"tracker":"TPB"},
      {"title":"No hash no link","bytes":1,"seeders":1}
    ],"total":{"value":3}}
    """#

    @Test func postsQueryAndFiltersEpisode() async throws {
        let stub = StubTransport(json: Self.json)
        let releases = try await KnabenProvider(transport: stub)
            .releases(for: .episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 4))
        #expect(releases.count == 1)
        #expect(releases[0].infoHash == String(repeating: "c", count: 40))
        #expect(releases[0].link.hasPrefix("magnet:?xt=urn:btih:cccc"))
        #expect(releases[0].sizeBytes == 2_100_000_000)
        #expect(releases[0].sources == [SourceTag(.direct, "Knaben")])

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1")
        #expect(request.bodyString.contains(#""query":"Severance S02E04""#))
        #expect(request.bodyString.contains(#""hide_xxx":true"#))
    }
}
