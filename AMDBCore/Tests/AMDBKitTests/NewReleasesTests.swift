import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct NewReleasesTests {
    static let today = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!

    @Test func moviesNewlyOutOnDigitalOrDiscInTheRegion() {
        let query = NewReleases.query(for: .movie, today: Self.today, region: "DE").parameters
        #expect(query["with_release_type"] == "4|5")
        #expect(query["region"] == "DE")
        #expect(query["release_date.gte"] == "2026-08-31")
        #expect(query["release_date.lte"] == "2026-10-15")
        #expect(query["sort_by"] == "release_date.desc")
        #expect(NewReleases.title(for: .movie) == "New to Stream")
    }

    @Test func showsWithAnEpisodeOutThisWeek() {
        let query = NewReleases.query(for: .tv, today: Self.today, region: "US").parameters
        #expect(query["air_date.gte"] == "2026-10-08")
        #expect(query["air_date.lte"] == "2026-10-15")
        #expect(query["without_genres"] == CuratedList.notSeries)
        #expect(NewReleases.title(for: .tv) == "New Episodes This Week")
    }

    @Test func browseLoadsTheRowAndFallsBackToTheUS() async {
        var catalog = FakeCatalog(popularMovies: [movie(1, "Popular")])
        catalog.discoverAnswer = { kind, query in
            guard query.parameters["with_release_type"] != nil else { return [] }
            return query.parameters["region"] == "US" ? [movie(7, "Runner")] : []
        }
        let today = Self.today
        let browse = BrowseModel(kind: .movie, catalog: catalog, now: { today }, region: "IR")
        await browse.load()
        #expect(browse.newReleases?.title == "New to Stream")
        #expect(browse.newReleases?.items.map(\.title) == ["Runner"])
        #expect(!browse.rows.contains { $0.id == "new" }, "it has its own place above the other rows")
    }

    @Test func tvBrowseLoadsNewEpisodesThisWeek() async {
        var catalog = FakeCatalog(popularShows: [show(1, "Popular")])
        catalog.discoverAnswer = { _, query in query.parameters["air_date.gte"] != nil ? [show(95396, "Severance")] : [] }
        let today = Self.today
        let browse = BrowseModel(kind: .tv, catalog: catalog, now: { today }, region: "US")
        await browse.load()
        #expect(browse.newReleases?.title == "New Episodes This Week")
        #expect(browse.newReleases?.items.map(\.tmdbID) == [95396])
    }

    @Test func noRowWhenTMDBHasNothing() async {
        var catalog = FakeCatalog(popularMovies: [movie(1, "Popular")])
        catalog.discoverAnswer = { _, _ in [] }
        let browse = BrowseModel(kind: .movie, catalog: catalog, region: "US")
        await browse.load()
        #expect(browse.newReleases == nil)
    }
}
