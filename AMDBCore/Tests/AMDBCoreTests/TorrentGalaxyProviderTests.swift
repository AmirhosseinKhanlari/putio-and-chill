import Foundation
import Testing
@testable import AMDBCore

/// Fixtures are real torrentgalaxy.info pages (October 2026), trimmed to the results table or the detail page's
/// download and info blocks. In the movie page one row was switched to Books and one given a magnet link, to cover both.
@Suite struct TorrentGalaxyProviderTests {
    static let detailHash = "C2F364BA7F59B22A1845B16FD8A1FC1783568F8B"

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The post id padded to 40 hex digits: each torrent gets its own hash.
    static func hash(forPost id: String) -> String { String((id + String(repeating: "0", count: 40)).prefix(40)) }

    /// Search pages answer with `search`; detail pages with the detail fixture, its hash swapped for the post's.
    static func site(search: String, failing: Set<String> = []) throws -> StubTransport {
        let detail = try fixture("torrentgalaxy-detail")
        return StubTransport { request in
            let parts = request.url!.path.split(separator: "/").map(String.init)
            guard parts.first == "post-detail" else { return (200, Data(search.utf8)) }
            // The site sometimes redirects a detail page to its home page (seen after bursts of requests); the app doesn't follow.
            if failing.contains(parts[1]) { return (302, Data()) }
            return (200, Data(detail.replacingOccurrences(of: detailHash, with: hash(forPost: parts[1]).uppercased()).utf8))
        }
    }

    static func detailRequests(_ stub: StubTransport) -> [String] {
        stub.requests.compactMap(\.url?.absoluteString).filter { $0.contains("/post-detail/") }
    }

    let dune = MediaQuery.movie(imdbID: "tt15239678", title: "Dune: Part Two", year: 2024)

    // MARK: Parsing

    @Test func parsesSearchRows() throws {
        let rows = TorrentGalaxyPage.rows(in: try Self.fixture("torrentgalaxy-search-movie"))
        #expect(rows.count == 5)
        #expect(rows[0] == TorrentGalaxyPage.Row(
            name: "Dune Part Two (2024) [1080p] [BluRay]", detailPath: "/post-detail/8a732c/dune-part-two-2024-1080p-bluray/",
            category: "Movies", sizeBytes: Int64(3.1 * 1024 * 1024 * 1024), seeders: 527, leechers: 52, infoHash: nil))
        #expect(rows[1].name == "Dune: Part Two 2024 2160p web YTS")
        #expect(rows[1].sizeBytes == Int64(7.4 * 1024 * 1024 * 1024))
        #expect(rows[3].category == "Books")
        #expect(rows[4].infoHash == "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12")
        #expect(rows[4].seeders == 251)

        let tv = TorrentGalaxyPage.rows(in: try Self.fixture("torrentgalaxy-search-tv"))
        #expect(tv.map(\.category) == ["TV", "TV", "TV", "TV"])
        #expect(tv[1].sizeBytes == Int64(507.5 * 1024 * 1024))
        #expect(tv[0].seeders == 20330)
    }

    @Test func noResultsPageHasNoRows() throws {
        #expect(TorrentGalaxyPage.rows(in: try Self.fixture("torrentgalaxy-search-empty")).isEmpty)
    }

    @Test func detailHashIsTheTorrentsOwnNotASimilarOnes() throws {
        let page = try Self.fixture("torrentgalaxy-detail")
        #expect(TorrentGalaxyPage.infoHash(inDetail: page) == Self.detailHash.lowercased())
        // Without the Info Hash field the Magnet Download button still gives it.
        let noField = page.replacingOccurrences(of: "Info Hash:", with: "Checksum:")
        #expect(TorrentGalaxyPage.infoHash(inDetail: noField) == Self.detailHash.lowercased())
        // With neither, the "similar torrents" magnet isn't taken instead.
        let neither = noField.replacingOccurrences(of: "dl-magnet", with: "dl-other")
        #expect(TorrentGalaxyPage.infoHash(inDetail: neither) == nil)
    }

    @Test func keywordsDropPunctuation() {
        #expect(TorrentGalaxyPage.keywords("Dune: Part Two 2024") == "Dune Part Two 2024")
        #expect(TorrentGalaxyPage.keywords("Grey's Anatomy S20E01") == "Greys Anatomy S20E01")
        #expect(TorrentGalaxyPage.keywords("Love, Death & Robots S01") == "Love Death Robots S01")
    }

    @Test func sizes() {
        #expect(TorrentGalaxyPage.bytes("1.5", unit: "GB") == 1_610_612_736)
        #expect(TorrentGalaxyPage.bytes("500", unit: "MB") == 524_288_000)
        #expect(TorrentGalaxyPage.bytes("1,024", unit: "KB") == 1_048_576)
        #expect(TorrentGalaxyPage.bytes("x", unit: "GB") == nil)
    }

    // MARK: Provider

    @Test func movieSearchBuildsMagnetsFromDetailHashes() async throws {
        let stub = try Self.site(search: Self.fixture("torrentgalaxy-search-movie"))
        let releases = try await TorrentGalaxyProvider(transport: stub).releases(for: dune)

        let search = try #require(stub.requests.first)
        #expect(search.url?.absoluteString == "https://torrentgalaxy.info/get-posts/keywords:Dune%20Part%20Two%202024:order:-se/")
        #expect(search.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0") == true)
        #expect(search.value(forHTTPHeaderField: "Accept")?.hasPrefix("text/html") == true)

        // The Books row is skipped; the row with its own magnet needs no detail page.
        #expect(releases.map(\.seeders) == [527, 299, 89, 251])
        #expect(Self.detailRequests(stub).count == 3)
        let first = releases[0]
        #expect(first.infoHash == Self.hash(forPost: "8a732c"))
        #expect(first.link == Magnet.make(infoHash: Self.hash(forPost: "8a732c"), name: "Dune Part Two (2024) [1080p] [BluRay]"))
        #expect(first.sizeBytes == Int64(3.1 * 1024 * 1024 * 1024))
        #expect(first.parsed.resolution == .fhd1080)
        #expect(first.sources == [SourceTag(.direct, "TorrentGalaxy")])
        #expect(releases[3].infoHash == "ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12")
    }

    @Test func readsOnlyTheBestSeededDetailPages() async throws {
        let stub = try Self.site(search: Self.fixture("torrentgalaxy-search-movie"))
        let releases = try await TorrentGalaxyProvider(transport: stub, detailLimit: 1).releases(for: dune)
        #expect(Self.detailRequests(stub) == ["https://torrentgalaxy.info/post-detail/8a732c/dune-part-two-2024-1080p-bluray/"])
        #expect(releases.map(\.seeders) == [527, 251])
    }

    @Test func failedDetailPageDropsOnlyThatRow() async throws {
        let stub = try Self.site(search: Self.fixture("torrentgalaxy-search-movie"), failing: ["89bee9"])
        let releases = try await TorrentGalaxyProvider(transport: stub).releases(for: dune)
        #expect(releases.map(\.seeders) == [527, 89, 251])
    }

    @Test func emptyResults() async throws {
        let stub = try Self.site(search: Self.fixture("torrentgalaxy-search-empty"))
        let releases = try await TorrentGalaxyProvider(transport: stub).releases(for: .text("zzqxjvwnotarealtitle 1987"))
        #expect(releases.isEmpty)
        #expect(stub.requests.count == 1)
    }

    @Test func searchPageErrorThrows() async {
        let stub = StubTransport(status: 503, json: "")
        await #expect(throws: AppError.http(service: "torrentgalaxy", status: 503)) {
            try await TorrentGalaxyProvider(transport: stub).releases(for: dune)
        }
    }

    // MARK: Through the aggregator

    @Test func episodeAndSeasonRelevance() async throws {
        let tv = try Self.fixture("torrentgalaxy-search-tv")
        let episodeStub = try Self.site(search: tv)
        let episode = await ReleaseAggregator(providers: [TorrentGalaxyProvider(transport: episodeStub)])
            .collect(for: .episode(imdbID: "tt3581920", title: "The Last of Us", season: 2, episode: 2))
        #expect(episode.failures.isEmpty)
        #expect(episode.releases.map(\.name) == ["The Last of Us S02E02 1080p WEB H264 SuccessfulCrab EZTV",
                                                 "The Last of Us S02E02 480p x264 mSD EZTV"])
        #expect(episodeStub.requests.first?.url?.absoluteString
            == "https://torrentgalaxy.info/get-posts/keywords:The%20Last%20of%20Us%20S02E02:order:-se/")

        let seasonStub = try Self.site(search: tv)
        let season = await ReleaseAggregator(providers: [TorrentGalaxyProvider(transport: seasonStub)])
            .collect(for: .season(imdbID: "tt3581920", title: "The Last of Us", season: 2))
        #expect(season.releases.map(\.name) == ["The Last of Us S02 1080p x265 ELiTE"])
        #expect(season.releases.first?.parsed.isSeasonPack == true)
        #expect(Self.detailRequests(seasonStub).count == 1)
    }

    @Test func mergesWithOtherSourcesByHash() async throws {
        let stub = try Self.site(search: Self.fixture("torrentgalaxy-search-movie"))
        let tpb = SourceTag(.direct, "TPB")
        let sameTorrent = Release(name: "Dune.Part.Two.2024.1080p.BluRay", link: "magnet:?xt=urn:btih:\(Self.hash(forPost: "8a732c"))",
                                  sizeBytes: 3_300_000_000, seeders: 900, sources: [tpb])
        let snapshot = await ReleaseAggregator(providers: [
            TorrentGalaxyProvider(transport: stub),
            FakeProvider(id: "apibay", result: .success([sameTorrent])),
        ]).collect(for: dune)
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.releases.count == 4)
        let merged = try #require(snapshot.releases.first { $0.infoHash == Self.hash(forPost: "8a732c") })
        #expect(merged.sources == [SourceTag(.direct, "TorrentGalaxy"), tpb])
        #expect(merged.seeders == 900)
    }

    @Test func failureDoesNotBreakOtherSources() async throws {
        let snapshot = await ReleaseAggregator(providers: [
            TorrentGalaxyProvider(transport: StubTransport(status: 500, json: "")),
            FakeProvider(id: "yts", result: .success([release("a", seeders: 3, tag: SourceTag(.direct, "YTS"))])),
        ]).collect(for: dune)
        #expect(snapshot.releases.count == 1)
        #expect(snapshot.failures == [ProviderFailure(providerID: "torrentgalaxy", error: .http(service: "torrentgalaxy", status: 500))])
    }
}
