import Foundation
import Testing
@testable import AMDBCore

@Suite struct ApibayProviderTests {
    static let json = #"""
    [{"id":"1","name":"Dune.Part.Two.2024.1080p.WEB.h264-ETHEL","info_hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","leechers":"10","seeders":"523","num_files":"1","size":"3000000000","imdb":"tt15239678"},
     {"id":"2","name":"Dune.1984.1080p.BluRay.x264","info_hash":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","leechers":"1","seeders":"20","num_files":"1","size":"9000000000","imdb":""}]
    """#

    @Test func mapsAndFiltersByYear() async throws {
        let stub = StubTransport(json: Self.json)
        let releases = try await ApibayProvider(transport: stub)
            .releases(for: .movie(imdbID: "tt15239678", title: "Dune Part Two", year: 2024))
        #expect(releases.count == 1)
        #expect(releases[0].infoHash == String(repeating: "a", count: 40))
        #expect(releases[0].seeders == 523)
        #expect(releases[0].sizeBytes == 3_000_000_000)
        #expect(releases[0].sources == [SourceTag(.direct, "TPB")])
        #expect(stub.requests.first?.queryItems["q"] == "Dune Part Two 2024")
        #expect(stub.requests.first?.url?.path == "/q.php")
    }

    @Test func noResultsSentinelIsEmpty() async throws {
        let json = #"[{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000","leechers":"0","seeders":"0","num_files":"0","size":"0","imdb":""}]"#
        let releases = try await ApibayProvider(transport: StubTransport(json: json)).releases(for: .text("zzz"))
        #expect(releases.isEmpty)
    }
}
