import Foundation
import Testing
@testable import AMDBCore

/// Shows TMDB has no IMDb id for ("Monster: The Ed Gein Story", TMDB 286801) are searched by title.
@Suite struct NoIMDbQueryTests {
    static let edGein = "Monster: The Ed Gein Story"

    @Test func searchTextDropsPunctuation() {
        #expect(MediaQuery.episode(imdbID: nil, title: Self.edGein, season: 1, episode: 1).searchText
            == "Monster The Ed Gein Story S01E01")
        #expect(MediaQuery.season(imdbID: nil, title: Self.edGein, season: 1).searchText == "Monster The Ed Gein Story S01")
        #expect(MediaQuery.movie(imdbID: nil, title: "Dune: Part Two", year: 2024).searchText == "Dune Part Two 2024")
        #expect(MediaQuery.searchTitle("Grey's Anatomy") == "Greys Anatomy")
        #expect(MediaQuery.episode(imdbID: nil, title: "X", season: 1, episode: 1).imdbID == nil)
        #expect(MediaQuery.episode(imdbID: "", title: "X", season: 1, episode: 1).imdbID == nil)
        #expect(MediaQuery.episode(imdbID: "tt1", title: "X", season: 1, episode: 1).imdbID == "tt1")
    }

    @Test func episodeReleasesMustNameTheShow() {
        let query = MediaQuery.episode(imdbID: nil, title: Self.edGein, season: 1, episode: 1)
        #expect(ReleaseRelevance.matches(ReleaseNameParser.parse("Monster The Ed Gein Story S01E01 1080p WEB h264-ETHEL"), query))
        #expect(ReleaseRelevance.matches(ReleaseNameParser.parse("Monster.The.Ed.Gein.Story.S01E01.720p.NF.WEB-DL"), query))
        // Another show's S01E01, and the base show, are not this one.
        #expect(!ReleaseRelevance.matches(ReleaseNameParser.parse("Monster S01E01 1080p BluRay"), query))
        #expect(!ReleaseRelevance.matches(ReleaseNameParser.parse("Wednesday S01E01 1080p WEB"), query))
        let season = MediaQuery.season(imdbID: nil, title: Self.edGein, season: 1)
        #expect(ReleaseRelevance.matches(ReleaseNameParser.parse("Monster The Ed Gein Story S01 1080p NF WEB-DL"), season))
        #expect(!ReleaseRelevance.matches(ReleaseNameParser.parse("Monster 2022 S03 1080p NF WEB-DL DDP5 1 Atmos H 264-GP-TV"), season))
    }

    /// TorrentGalaxy's search for "Wildwood 2026" also finds "Wellwood 2025": a year off by one isn't enough.
    @Test func movieReleasesMustNameTheMovie() {
        func matches(_ name: String, _ title: String, _ year: Int?) -> Bool {
            ReleaseRelevance.matches(ReleaseNameParser.parse(name), .movie(imdbID: "tt1", title: title, year: year))
        }
        #expect(matches("Wildwood 2026 1080p WEB-DL x264", "Wildwood", 2026))
        #expect(!matches("Wellwood 2025 1080p web YTS", "Wildwood", 2026))
        #expect(!matches("Wellwood (2025) 1080p bluray 5.1-LAMA", "Wildwood", 2026))
        // Punctuation, a dropped subtitle and words added after the title are the same movie.
        #expect(matches("Dune.Part.Two.2024.2160p.WEB-DL", "Dune: Part Two", 2024))
        #expect(matches("Glass Onion 2022 1080p NF WEB-DL", "Glass Onion: A Knives Out Mystery", 2022))
        #expect(matches("Dune Part One 2021 1080p BluRay", "Dune", 2021))
        #expect(matches("www.UIndex.org - Wildwood 2026 720p", "Wildwood", 2026))
        // Sequels are told apart by the year, and another movie that merely starts the same way doesn't count.
        #expect(!matches("Dune 1984 1080p BluRay", "Dune", 2021))
        #expect(!matches("Wildwood Nights 2026 1080p", "Wild", 2026))
        #expect(!matches("Spider 2026 1080p", "Spider-Man", 2026))
    }

    @Test func showTitleComparison() {
        #expect(ReleaseRelevance.sameShow("The Last of Us", "The Last of Us"))
        #expect(ReleaseRelevance.sameShow("Last of Us", "The Last of Us"))
        #expect(ReleaseRelevance.sameShow("Shogun", "Shōgun"))
        #expect(ReleaseRelevance.sameShow("The Office US", "The Office"))
        #expect(ReleaseRelevance.sameShow("Doctor Who 2005", "Doctor Who"))
        #expect(ReleaseRelevance.sameShow("Law and Order", "Law & Order"))
        #expect(ReleaseRelevance.sameShow("www.UIndex.org - Severance", "Severance"))
        #expect(!ReleaseRelevance.sameShow("The Office Christmas Special", "The Office"))
        #expect(!ReleaseRelevance.sameShow("Monster", "Monster: The Ed Gein Story"))
        #expect(ReleaseRelevance.sameShow("", "Severance"))
    }

    @Test func chillSearchesByTitleWithoutIMDbID() async throws {
        let stub = StubTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/GetIndexers") {
                return (200, Data(#"{"indexers":[{"id":"tpb","name":"TPB","enabled":true}]}"#.utf8))
            }
            if path.hasSuffix("/Search") {
                return (200, Data(#"""
                {"results":[
                 {"title":"Monster The Ed Gein Story S01E01 1080p WEB h264-ETHEL","indexer":"tpb","link":"magnet:?xt=urn:btih:1111111111111111111111111111111111111111","seeders":"500","size":"2000000000"},
                 {"title":"Monster S01E01 1080p BluRay","indexer":"tpb","link":"magnet:?xt=urn:btih:2222222222222222222222222222222222222222","seeders":"50","size":"1000000000"}]}
                """#.utf8))
            }
            return (404, Data())
        }
        let releases = try await ChillProvider(token: "tok", transport: stub)
            .releases(for: .episode(imdbID: nil, title: Self.edGein, season: 1, episode: 1))
        #expect(releases.map(\.infoHash) == [String(repeating: "1", count: 40)])
        let search = try #require(stub.requests.first { $0.url!.path.hasSuffix("/Search") })
        #expect(search.bodyString.contains(#""query":"Monster The Ed Gein Story S01E01""#))
        #expect(!stub.requests.contains { $0.url!.path.hasSuffix("/GetTVShowEpisodeDownload") })
    }

    @Test func eztvSkipsWithoutIMDbID() async throws {
        let stub = StubTransport(json: #"{"torrents":[]}"#)
        let releases = try await EZTVProvider(transport: stub)
            .releases(for: .season(imdbID: nil, title: Self.edGein, season: 1))
        #expect(releases.isEmpty)
        #expect(stub.requests.isEmpty)
    }

    @Test func ytsSearchesByTitleWithoutIMDbID() async throws {
        let stub = StubTransport(json: #"""
        {"status":"ok","data":{"movies":[
          {"title":"Heat","year":1995,"torrents":[{"hash":"0123456789ABCDEF0123456789ABCDEF01234567","quality":"1080p","seeds":10,"size_bytes":1}]},
          {"title":"Heat","year":2013,"torrents":[{"hash":"89ABCDEF0123456789ABCDEF0123456789ABCDEF","quality":"1080p","seeds":5,"size_bytes":1}]},
          {"title":"Heat Wave","year":1995,"torrents":[{"hash":"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF","quality":"720p","seeds":1,"size_bytes":1}]}]}}
        """#)
        let releases = try await YTSProvider(transport: stub).releases(for: .movie(imdbID: nil, title: "Heat", year: 1995))
        #expect(releases.map(\.infoHash) == ["0123456789abcdef0123456789abcdef01234567"])
        #expect(stub.requests.first?.queryItems["query_term"] == "Heat")
    }

    @Test func textSourcesFilterOtherShows() async throws {
        let json = #"""
        [{"id":"1","name":"Monster The Ed Gein Story S01E01 1080p WEB h264-ETHEL","info_hash":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","leechers":"1","seeders":"900","num_files":"1","size":"3000000000","imdb":""},
         {"id":"2","name":"Monster S01E01 Herr Dr Tenma","info_hash":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","leechers":"1","seeders":"20","num_files":"1","size":"900000000","imdb":""}]
        """#
        let stub = StubTransport(json: json)
        let releases = try await ApibayProvider(transport: stub)
            .releases(for: .episode(imdbID: nil, title: Self.edGein, season: 1, episode: 1))
        #expect(releases.map(\.seeders) == [900])
        #expect(stub.requests.first?.queryItems["q"] == "Monster The Ed Gein Story S01E01")
    }
}
