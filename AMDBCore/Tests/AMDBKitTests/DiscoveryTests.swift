import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct MyListTests {
    @Test func toggleAddsNewestFirstRemovesAndPersists() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        let list = MyList(store: LocalStore(fileURL: url))
        await list.load()
        await list.toggle(movie(1, "Dune"))
        await list.toggle(show(2, "Severance"))
        #expect(list.items.map(\.title) == ["Severance", "Dune"])
        #expect(list.contains(movie(1, "Dune")))
        #expect(!list.contains(CatalogItem(tmdbID: 1, mediaType: .tv, title: "Other")))
        await list.toggle(movie(1, "Dune"))
        #expect(list.items.map(\.title) == ["Severance"])

        let reloaded = MyList(store: LocalStore(fileURL: url))
        await reloaded.load()
        #expect(reloaded.items.map(\.tmdbID) == [2])
        #expect(reloaded.items.first?.catalogItem.mediaType == .tv)
    }
}

@MainActor @Suite struct SurpriseTests {
    @Test func moodsMapToGenresPerKind() {
        #expect(Mood.laugh.genreIDs(for: .movie) == [35])
        #expect(Mood.mindBending.genreIDs(for: .tv).contains(10765))
        #expect(Mood.anything.genreIDs(for: .movie).isEmpty)
    }

    @Test func rollsAPickAndAvoidsImmediateRepeats() async {
        var catalog = FakeCatalog()
        catalog.discovered = [movie(1, "A"), movie(2, "B")]
        let surprise = SurpriseModel(catalog: catalog, random: { range in range.lowerBound })
        await surprise.roll(kind: .movie, mood: .laugh)
        let first = surprise.pick?.tmdbID
        await surprise.roll(kind: .movie, mood: .laugh)
        #expect(first != nil)
        #expect(surprise.pick?.tmdbID != first)
    }

    @Test func offersAlternativesAndSwapsThem() async {
        var catalog = FakeCatalog()
        catalog.discovered = (1...9).map { CatalogItem(tmdbID: $0, mediaType: .movie, title: "M\($0)", backdropPath: $0 == 5 ? nil : "/b\($0).jpg") }
        let surprise = SurpriseModel(catalog: catalog, random: { range in range.lowerBound })
        await surprise.roll(kind: .movie, mood: .anything)
        #expect(surprise.pick?.tmdbID == 1)
        #expect(surprise.alternatives.map(\.tmdbID) == [2, 3, 4, 6, 7, 8])
        surprise.choose(surprise.alternatives[2])
        #expect(surprise.pick?.tmdbID == 4)
        #expect(surprise.alternatives.map(\.tmdbID) == [2, 3, 1, 6, 7, 8])
    }

    @Test func emptyResultsLeaveNoPick() async {
        let surprise = SurpriseModel(catalog: FakeCatalog(), random: { $0.lowerBound })
        await surprise.roll(kind: .tv, mood: .scare)
        #expect(surprise.pick == nil)
        #expect(surprise.isEmpty)
    }
}
