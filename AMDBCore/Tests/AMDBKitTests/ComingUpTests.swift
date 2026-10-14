import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct ComingUpTests {
    /// Tuesday 2026-10-13 12:00 UTC
    let today = Date(timeIntervalSince1970: 1_791_892_800)

    func episode(_ title: String, on date: String) -> UpcomingEpisode {
        UpcomingEpisode(show: CatalogItem(tmdbID: title.count, mediaType: .tv, title: title), season: 1, episode: 2,
                        name: "Next", airDate: date, stillPath: nil)
    }

    @Test func episodesGroupByDayWithFriendlyNames() {
        let days = ComingUpModel.days([episode("Slow Horses", on: "2026-10-15"), episode("Andor", on: "2026-10-13"),
                                       episode("The Bear", on: "2026-10-14"), episode("Shogun", on: "2026-11-02"),
                                       episode("Old", on: "2026-10-01"), episode("Far", on: "2027-01-01")], today: today)
        #expect(days.map(\.label) == ["Today", "Tomorrow", "Thursday", "Nov 2"])
        #expect(days.flatMap(\.episodes).map(\.show.title) == ["Andor", "The Bear", "Slow Horses", "Shogun"])
    }

    @Test func comingSoonIsFutureAndSoonestFirst() {
        let items = [DatedItem(item: CatalogItem(tmdbID: 1, mediaType: .movie, title: "Later"), date: "2026-12-01"),
                     DatedItem(item: CatalogItem(tmdbID: 2, mediaType: .movie, title: "Out"), date: "2026-10-01"),
                     DatedItem(item: CatalogItem(tmdbID: 3, mediaType: .movie, title: "Soon"), date: "2026-10-20"),
                     DatedItem(item: CatalogItem(tmdbID: 4, mediaType: .movie, title: "TBA"), date: nil)]
        #expect(ComingUpModel.upcoming(items, after: "2026-10-13").map(\.item.title) == ["Soon", "Later"])
        #expect(ComingUpModel.shortDate("2026-10-24") == "Oct 24")
    }

    @Test func yourShowsArePutioFirstThenMyListEachOnce() {
        let entry = LibraryEntry(file: PutioFile(id: 1, name: "Severance.S02E04.mkv", fileType: "VIDEO"),
                                 match: LibraryMatch(tmdbID: 95396, mediaType: .tv, season: 2, episode: 4, confidence: 1, title: "Severance"),
                                 folderName: nil)
        let movie = LibraryEntry(file: PutioFile(id: 2, name: "Heat.mkv", fileType: "VIDEO"),
                                 match: LibraryMatch(tmdbID: 949, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "Heat"), folderName: nil)
        let saved = [SavedTitle(CatalogItem(tmdbID: 95396, mediaType: .tv, title: "Severance")),
                     SavedTitle(CatalogItem(tmdbID: 83867, mediaType: .tv, title: "Andor"))]
        #expect(ComingUpModel.yourShows(library: [entry, movie], myList: saved) == [95396, 83867])
    }
}
