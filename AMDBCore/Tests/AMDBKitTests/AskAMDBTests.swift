import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct AskAMDBTests {
    @Test func twisty90sThrillerUnderTwoHours() {
        let request = AskRequest(kind: .movie, genres: ["Thriller", "Mystery"], yearFrom: 1990, yearTo: 1999, maxRuntime: 120,
                                 minRating: 7)
        let p = request.query(for: .movie, keywordIDs: [9748]).parameters
        #expect(p["with_genres"] == "53,9648")
        #expect(p["primary_release_date.gte"] == "1990-01-01")
        #expect(p["primary_release_date.lte"] == "1999-12-31")
        #expect(p["with_runtime.lte"] == "120")
        #expect(p["vote_average.gte"] == "7.0")
        #expect(p["with_keywords"] == "9748")
        #expect(request.summary == "Movies · Thriller · Mystery · 1990–1999 · under 2 h · 7+")
    }

    @Test func movieGenreWordsWorkForShows() {
        #expect(AskRequest.genreID("Science Fiction", kind: .tv) == 10765)
        #expect(AskRequest.genreID("Thriller", kind: .tv) == 9648)
        #expect(AskRequest.genreID("sci-fi", kind: .movie) == 878)
        #expect(AskRequest.genreID("Nonsense", kind: .movie) == nil)
    }

    @Test func anyKindSearchesBothAndAlternates() async {
        var catalog = FakeCatalog(popularMovies: [movie(1, "M1"), movie(2, "M2")], popularShows: [show(3, "S1")])
        catalog.failAll = false
        let results = await AskSearch.run(AskRequest(kind: .any, genres: ["Comedy"]), catalog: catalog)
        #expect(results.map(\.title) == ["M1", "S1", "M2"])
    }

    @Test func likeSomethingUsesItsRecommendations() async {
        let severance = show(95396, "Severance")
        var catalog = FakeCatalog(multi: ["severance": [severance]])
        catalog.details[95396] = TitleDetail(item: severance, imdbID: nil,
                                             recommendations: [show(1, "Silo", year: 2023), movie(2, "Old Film", year: 1970)])
        let results = await AskSearch.run(AskRequest(kind: .tv, similarTo: "Severance"), catalog: catalog)
        #expect(results.map(\.title) == ["Silo"])
    }
}
