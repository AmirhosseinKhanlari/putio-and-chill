import Foundation
import Testing
@testable import AMDBCore

@Suite struct ChillProviderTests {
    static func router() -> StubTransport {
        StubTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/GetIndexers") {
                return (200, Data(#"{"indexers":[{"id":"yts","name":"YTS","enabled":true},{"id":"tpb","name":"TPB","enabled":true},{"id":"off","name":"Off"}]}"#.utf8))
            }
            if path.hasSuffix("/Search") {
                let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if body.contains(#""indexerId":"yts""#) {
                    return (200, Data(#"{"query":"Furiosa 2024","results":[{"id":"r1","title":"Furiosa (2024) [1080p] [WEBRip]","indexer":"yts","link":"magnet:?xt=urn:btih:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","seeders":"1200","size":"2900000000","source":"YTS","releaseInfo":{"title":"Furiosa","year":2024,"resolution":"1080p"}}]}"#.utf8))
                }
                return (503, Data(#"{"code":"unavailable","message":"indexer is down"}"#.utf8))
            }
            if path.hasSuffix("/GetTVShowEpisodeDownload") {
                return (200, Data(#"{"download":{"title":"Severance.S02E04.1080p.WEB.H264-NTb","link":"magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff","size":"2100000000","seeders":"88","resolution":"1080p","indexer":"eztv","seasonNumber":2,"episodeNumber":4},"searchQuery":"Severance S02E04"}"#.utf8))
            }
            if path.hasSuffix("/GetTVShowSeasonDownloads") {
                return (200, Data(#"{"seasonPack":{"title":"Severance.S02.1080p.WEB.H264-NTb","link":"magnet:?xt=urn:btih:9999999999999999999999999999999999999999","size":"20000000000","seeders":"30","indexer":"tpb","seasonNumber":2},"episodes":[]}"#.utf8))
            }
            return (404, Data())
        }
    }

    @Test func searchesEnabledIndexersAndToleratesOneFailure() async throws {
        let stub = Self.router()
        let chill = ChillProvider(token: "tok", transport: stub)
        let releases = try await chill.releases(for: .movie(imdbID: "tt12037194", title: "Furiosa", year: 2024))

        #expect(releases.count == 1)
        #expect(releases[0].seeders == 1200)
        #expect(releases[0].sizeBytes == 2_900_000_000)
        #expect(releases[0].sources == [SourceTag(.chill, "YTS")])
        #expect(releases[0].parsed.title == "Furiosa")
        #expect(releases[0].infoHash == String(repeating: "e", count: 40))

        let searches = stub.requests.filter { $0.url!.path.hasSuffix("/Search") }
        #expect(searches.count == 2)
        #expect(searches.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        #expect(searches.allSatisfy { $0.url!.path.hasPrefix("/v4/chill.v4.UserService/") })
    }

    @Test func episodeUsesTVRPC() async throws {
        let releases = try await ChillProvider(token: "tok", transport: Self.router())
            .releases(for: .episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 4))
        #expect(releases.count == 1)
        #expect(releases[0].seeders == 88)
        #expect(releases[0].sources == [SourceTag(.chill, "eztv")])
    }

    @Test func seasonUsesSeasonPack() async throws {
        let releases = try await ChillProvider(token: "tok", transport: Self.router())
            .releases(for: .season(imdbID: "tt11280740", title: "Severance", season: 2))
        #expect(releases.map(\.infoHash) == [String(repeating: "9", count: 40)])
    }

    @Test func unauthorizedPropagates() async {
        let chill = ChillProvider(token: "bad", transport: StubTransport(status: 401, json: #"{"code":"unauthenticated"}"#))
        await #expect(throws: AppError.unauthorized(service: "chill")) {
            _ = try await chill.releases(for: .text("x"))
        }
    }
}
