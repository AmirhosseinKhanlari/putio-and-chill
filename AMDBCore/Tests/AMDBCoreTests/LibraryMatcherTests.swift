import Foundation
import Testing
@testable import AMDBCore

struct FakeCatalog: CatalogSearching {
    var movies: [CatalogItem] = []
    var shows: [CatalogItem] = []
    var seasonCounts: [Int: Int] = [:]
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] { movies }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] { shows }
    func seasonCount(tvID: Int) async throws -> Int? { seasonCounts[tvID] }
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
        #expect(match == LibraryMatch(tmdbID: 2, mediaType: .movie, season: nil, episode: nil, confidence: 1.0,
                                      title: "Dune: Part Two", year: 2024))
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

    /// What TMDB's /search/tv returns for "Monster" (trimmed): the 2004 anime first, Netflix's anthology seasons as
    /// separate shows with longer titles.
    static let monsterSearch = FakeCatalog(
        shows: [item(30981, "Monster", 2004, kind: .tv), item(113988, "Dahmer – Monster: The Jeffrey Dahmer Story", 2022, kind: .tv),
                item(225634, "Monsters: The Lyle and Erik Menendez Story", 2024, kind: .tv),
                item(286801, "Monster: The Ed Gein Story", 2025, kind: .tv), item(299939, "Monster: The Lizzie Borden Story", 2026, kind: .tv)],
        seasonCounts: [30981: 1, 113988: 1, 225634: 1, 286801: 1, 299939: 1])

    @Test func yearInNameRulesOutSameTitleFromAnotherYear() async throws {
        let matcher = LibraryMatcher(catalog: Self.monsterSearch)
        // Netflix's "Monster" season 3 named as the anthology: not the 2004 anime (one season, another year).
        #expect(try await matcher.match(fileName: "Monster.2022.S03E01.1080p.NF.WEB-DL.DDP5.1.Atmos.H.264-GP.mkv") == nil)
        #expect(try await matcher.match(fileName: "Monster.S03E01.1080p.mkv") == nil)
        // The anime itself still matches.
        let anime = try await matcher.match(fileName: "Monster.S01E05.1080p.BluRay.mkv")
        #expect(anime?.tmdbID == 30981)
        #expect(anime?.confidence == 1.0)
        // A year that fits a longer "Monster: …" title picks it.
        let edGein = try await matcher.match(fileName: "Monster.2025.S01E02.1080p.mkv")
        #expect(edGein?.tmdbID == 286801)
        #expect(edGein?.season == 1)
        #expect(edGein?.episode == 2)
        #expect(try await matcher.match(fileName: "Monster.2026.S01E01.mkv")?.tmdbID == 299939)
        // Two "Monster: …" titles from 2024: ambiguous, so no guess.
        let twoIn2024 = FakeCatalog(shows: [item(30981, "Monster", 2004, kind: .tv), item(1, "Monster: One", 2024, kind: .tv),
                                            item(2, "Monster: Two", 2024, kind: .tv)], seasonCounts: [30981: 1])
        #expect(try await LibraryMatcher(catalog: twoIn2024).match(fileName: "Monster.2024.S02E01.mkv") == nil)
    }

    @Test func fullTitleMatchesItsShow() async throws {
        let match = try await LibraryMatcher(catalog: Self.monsterSearch)
            .match(fileName: "Monster.The.Ed.Gein.Story.S01E08.1080p.HEVC.x265-MeGusta.mkv")
        #expect(match?.tmdbID == 286801)
        #expect(match?.episode == 8)
        #expect(match?.confidence == 1.0)
    }

    @Test func sameTitleShowsPickedByYear() async throws {
        let catalog = FakeCatalog(shows: [item(1, "Doctor Who", 1963, kind: .tv), item(2, "Doctor Who", 2005, kind: .tv),
                                          item(3, "Doctor Who", 2023, kind: .tv)])
        let matcher = LibraryMatcher(catalog: catalog)
        #expect(try await matcher.match(fileName: "Doctor.Who.2005.S04E01.720p.mkv")?.tmdbID == 2)
        #expect(try await matcher.match(fileName: "Doctor.Who.2023.S01E01.mkv")?.tmdbID == 3)
        // No year: the first same-title show, as before.
        #expect(try await matcher.match(fileName: "Doctor.Who.S01E01.mkv")?.tmdbID == 1)
    }

    @Test func otherYearStillMatchesWhenTheSeasonExists() async throws {
        let catalog = FakeCatalog(shows: [item(7, "Severance", 2022, kind: .tv)], seasonCounts: [7: 2])
        let match = try await LibraryMatcher(catalog: catalog).match(fileName: "Severance.2025.S02E04.mkv")
        #expect(match?.tmdbID == 7)
        #expect(match?.confidence == 0.6)
        // Unknown season counts don't rule a show out.
        let unknown = try await LibraryMatcher(catalog: FakeCatalog(shows: [item(8, "Andor", 2022, kind: .tv)]))
            .match(fileName: "Andor.S02E01.mkv")
        #expect(unknown?.tmdbID == 8)
    }

    @Test func normalize() {
        #expect(LibraryMatcher.normalize("Shōgun") == "shogun")
        #expect(LibraryMatcher.normalize("Dune: Part Two") == "duneparttwo")
        #expect(LibraryMatcher.normalize("Fast & Furious") == "fastandfurious")
    }

    @Test func libraryMatchIsCodable() throws {
        let match = LibraryMatch(tmdbID: 7, mediaType: .tv, season: 1, episode: 2, confidence: 0.7,
                                 title: "Show", year: 2020, posterPath: "/p.jpg", backdropPath: nil)
        let data = try JSONEncoder().encode(match)
        #expect(try JSONDecoder().decode(LibraryMatch.self, from: data) == match)
    }
}
