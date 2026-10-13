import Foundation
import Testing
@testable import AMDBCore

struct FakeCatalog: CatalogSearching {
    var movies: [CatalogItem] = []
    var shows: [CatalogItem] = []
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] { movies }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] { shows }
}

func item(_ id: Int, _ title: String, _ year: Int?, kind: MediaKind = .movie) -> CatalogItem {
    let key = kind == .movie ? "title" : "name"
    let dateKey = kind == .movie ? "release_date" : "first_air_date"
    let date = year.map { "\"\($0)-01-01\"" } ?? "null"
    let json = #"{"id":\#(id),"\#(key)":"\#(title)","\#(dateKey)":\#(date)}"#
    return try! JSONDecoder.snakeCase.decode(CatalogItem.self, from: Data(json.utf8))
}

@Suite struct LibraryMatcherTests {
    @Test func exactTitleAndYear() async throws {
        let catalog = FakeCatalog(movies: [item(1, "Dune", 1984), item(2, "Dune: Part Two", 2024)])
        let match = try await LibraryMatcher(catalog: catalog).match(fileName: "Dune.Part.Two.2024.1080p.WEB.h264-ETHEL.mkv")
        #expect(match == LibraryMatch(tmdbID: 2, mediaType: .movie, season: nil, episode: nil, confidence: 1.0))
    }

    @Test func tvEpisodeWithDiacritics() async throws {
        let catalog = FakeCatalog(shows: [item(126308, "Shōgun", 2024, kind: .tv)])
        let match = try await LibraryMatcher(catalog: catalog).match(fileName: "Shogun.S01E07.1080p.WEB.h264")
        #expect(match?.tmdbID == 126308)
        #expect(match?.mediaType == .tv)
        #expect(match?.season == 1)
        #expect(match?.episode == 7)
        #expect(match?.confidence == 1.0)
    }

    @Test func titleOnlyMatchIsLowerConfidence() async throws {
        let catalog = FakeCatalog(movies: [item(5, "Heat", 1995)])
        let match = try await LibraryMatcher(catalog: catalog).match(fileName: "Heat.2010.720p")
        #expect(match?.confidence == 0.7)
    }

    @Test func noPlausibleMatch() async throws {
        let catalog = FakeCatalog(movies: [item(9, "Something Else", 1999)])
        #expect(try await LibraryMatcher(catalog: catalog).match(fileName: "Heat.2010.720p") == nil)
    }

    @Test func normalize() {
        #expect(LibraryMatcher.normalize("Shōgun") == "shogun")
        #expect(LibraryMatcher.normalize("Dune: Part Two") == "duneparttwo")
        #expect(LibraryMatcher.normalize("Fast & Furious") == "fastandfurious")
    }
}
