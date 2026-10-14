import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct NextUpTests {
    /// 2026-10-14
    let today = Date(timeIntervalSince1970: 1_791_979_200)

    func episodes(_ count: Int, aired: Int? = nil) -> [Episode] {
        (1...count).map { n in
            Episode(number: n, name: "Episode \(n)", overview: "Story \(n)", stillPath: "/s\(n).jpg",
                    airDate: n <= (aired ?? count) ? "2026-0\(min(n, 9))-01" : "2026-12-01")
        }
    }

    @Test func nextInTheSameSeason() {
        let picked = NextUpFinder.pick(after: (2, 4), from: episodes(8).map { (2, $0) }, today: today)
        #expect(picked?.0 == 2)
        #expect(picked?.1.number == 5)
    }

    @Test func firstOfTheNextSeasonAfterAFinale() {
        let candidates = episodes(8).map { (2, $0) } + episodes(6).map { (3, $0) }
        let picked = NextUpFinder.pick(after: (2, 8), from: candidates, today: today)
        #expect(picked.map { [$0.0, $0.1.number] } == [3, 1])
    }

    @Test func unairedEpisodesAreNotOffered() {
        let picked = NextUpFinder.pick(after: (1, 3), from: episodes(8, aired: 3).map { (1, $0) }, today: today)
        #expect(picked == nil)
    }

    @Test func creditsLengthScalesWithTheEpisode() {
        #expect(NextUp.creditsLength(duration: 22 * 60) == 33)
        #expect(NextUp.creditsLength(duration: 60 * 60) == 60)
        #expect(NextUp.creditsLength(duration: 10 * 60) == 20)
    }

    @Test func findsFromTMDBAndKnowsWhenItsInPutio() async {
        let severance = show(95396, "Severance")
        var catalog = FakeCatalog()
        catalog.details[95396] = TitleDetail(item: severance, imdbID: "tt11280740",
                                             seasons: [SeasonSummary(number: 1, name: "Season 1", episodeCount: 9, posterPath: nil),
                                                       SeasonSummary(number: 2, name: "Season 2", episodeCount: 10, posterPath: nil)])
        catalog.seasons[1] = episodes(9)
        catalog.seasons[2] = episodes(10)
        let index = LibraryIndex(store: LocalStore(fileURL: nil))
        let next = await NextUpFinder.find(tmdbID: 95396, season: 1, episode: 9, catalog: catalog, library: index, today: today)
        #expect(next?.label == "S2 E1")
        #expect(next?.name == "Episode 1")
        #expect(next?.isInPutio == false)
        #expect(next?.query == .episode(imdbID: "tt11280740", title: "Severance", season: 2, episode: 1))
    }

    @Test func picksUpTheEpisodeOnceItsInPutio() async {
        let library = LibraryIndex(store: LocalStore(fileURL: nil))
        library.configure(putio: LibraryIndexTests.tree(), catalog: LibraryIndexTests.catalog)
        let next = NextUp(showTitle: "Severance", season: 2, episode: 4, name: "Woe's Hollow", overview: "", stillPath: nil,
                          entry: nil, query: nil,
                          target: TransferTarget(tmdbID: 95396, kind: .tv, title: "Severance", posterPath: nil, backdropPath: nil,
                                                 season: 2, episode: 4))
        #expect(next.resolved(in: library).isInPutio == false)
        await library.refresh()
        #expect(next.resolved(in: library).entry?.id == 12)
    }
}
