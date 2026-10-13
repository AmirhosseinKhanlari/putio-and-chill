import AMDBCore
import Testing
@testable import AMDBKit

@Suite struct LibraryCardsTests {
    func entry(_ id: Int64, _ match: LibraryMatch?) -> LibraryEntry {
        LibraryEntry(file: PutioFile(id: id, name: "f\(id).mkv", fileType: "VIDEO"), match: match, folderName: nil)
    }

    var entries: [LibraryEntry] {
        [entry(1, LibraryMatch(tmdbID: 10, mediaType: .tv, season: 1, episode: 1, confidence: 1, title: "Show", posterPath: "/s.jpg")),
         entry(2, LibraryMatch(tmdbID: 20, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "Film")),
         entry(3, LibraryMatch(tmdbID: 10, mediaType: .tv, season: 1, episode: 2, confidence: 1, title: "Show")),
         entry(4, nil)]
    }

    @Test func groupsEpisodesIntoShows() {
        let cards = LibraryCard.cards(from: entries, filter: .all)
        #expect(cards.map(\.id) == ["s-10", "m-2", "f-4"])
        guard case let .show(_, title, poster, episodes) = cards[0] else { Issue.record("not a show"); return }
        #expect(title == "Show")
        #expect(poster == "/s.jpg")
        #expect(episodes.map(\.id) == [1, 3])
    }

    @Test func filters() {
        #expect(LibraryCard.cards(from: entries, filter: .movies).map(\.id) == ["m-2"])
        #expect(LibraryCard.cards(from: entries, filter: .tv).map(\.id) == ["s-10"])
        #expect(LibraryCard.cards(from: entries, filter: .other).map(\.id) == ["f-4"])
    }
}
