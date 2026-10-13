import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct LocalStoreTests {
    @Test func persistsAndReloads() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amdb-\(UUID().uuidString)/state.json")
        let store = LocalStore(fileURL: url)
        let pending = PendingTransfer(transferID: 7, tmdbID: 1, kind: .movie, title: "Dune", posterPath: nil,
                                      backdropPath: nil, season: nil, episode: nil, createdAt: Date(timeIntervalSince1970: 0))
        await store.update {
            $0.pending.append(pending)
            $0.matches[5] = LibraryMatch(tmdbID: 1, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "Dune")
            $0.lastPlayed = PlayedTitle(tmdbID: 1, kind: .movie, title: "Dune")
        }
        let state = await LocalStore(fileURL: url).snapshot
        #expect(state.pending == [pending])
        #expect(state.matches[5]?.title == "Dune")
        #expect(state.lastPlayed?.title == "Dune")
    }

    @Test func memoryOnlyStoreStartsEmpty() async {
        #expect(await LocalStore(fileURL: nil).snapshot == LocalState())
    }

    @Test func recentSearchesAreDedupedAndCapped() async {
        let store = LocalStore(fileURL: nil)
        for query in (1...12).map(String.init) { await store.addRecentSearch(query) }
        await store.addRecentSearch("5")
        await store.addRecentSearch("   ")
        let recent = await store.snapshot.recentSearches
        #expect(recent.count == 10)
        #expect(recent.first == "5")
        #expect(recent.filter { $0 == "5" }.count == 1)
    }
}
