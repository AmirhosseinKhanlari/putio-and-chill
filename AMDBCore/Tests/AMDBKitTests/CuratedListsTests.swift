import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct CuratedListsTests {
    /// 2026-10-13 12:00 UTC
    let today = Date(timeIntervalSince1970: 1_791_892_800)

    @Test func newOnNetflixMoviesAreRecentNetflixReleases() {
        let p = CuratedList.newOnNetflix.query(for: .movie, today: today).parameters
        #expect(p["with_watch_providers"] == "8")
        #expect(p["watch_region"] == "US")
        #expect(p["with_watch_monetization_types"] == "flatrate")
        #expect(p["primary_release_date.lte"] == "2026-10-13")
        #expect(p["primary_release_date.gte"] == "2026-06-15")
    }

    @Test func newOnDisneyShowsAreItsOwnShowsWithEpisodesThisMonth() {
        let p = CuratedList.newOnDisney.query(for: .tv, today: today).parameters
        #expect(p["with_networks"] == "2739")
        #expect(p["with_watch_providers"] == nil)
        #expect(p["without_genres"] == "10767|10763|10764|10766")
        #expect(p["air_date.gte"] == "2026-09-13")
        #expect(p["air_date.lte"] == "2026-10-13")
    }

    @Test func returningThisWeekIsExistingShowsAiringInSevenDays() {
        let p = CuratedList.returningThisWeek.query(for: .tv, today: today).parameters
        #expect(p["air_date.gte"] == "2026-10-13")
        #expect(p["air_date.lte"] == "2026-10-20")
        #expect(p["first_air_date.lte"] == "2026-07-15")
    }

    @Test func showOnlyListsSkipMovies() {
        #expect(!CuratedList.newSeries.applies(to: .movie))
        #expect(!CuratedList.returningThisWeek.applies(to: .movie))
        #expect(CuratedList.criticallyAcclaimed.applies(to: .movie) && CuratedList.criticallyAcclaimed.applies(to: .tv))
    }

    @Test func criticallyAcclaimedIsHighlyRatedAndRecent() {
        let p = CuratedList.criticallyAcclaimed.query(for: .movie, today: today).parameters
        #expect(p["sort_by"] == "vote_average.desc")
        #expect(p["vote_average.gte"] == "7.5")
        #expect(p["vote_count.gte"] == "1000")
        #expect(p["primary_release_date.gte"] == "2021-10-14")
    }
}
