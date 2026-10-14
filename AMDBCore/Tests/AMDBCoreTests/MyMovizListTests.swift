import Foundation
import Testing
@testable import AMDBCore

@Suite struct MyMovizListTests {
    static let page = """
    <article class="mv-ritem">
    <a class="mv-card" href="/movies/225557/unit-23-reloaded-2024" data-guid="225557" title="Unit 23 Reloaded 2024">
    <div class="mv-card__poster"><img class="mv-card__img" src="https://imgsources.cc/./images/cover/10/tt10303912.jpg" alt="Unit 23 Reloaded 2024">
    </div></a></article>
    <article class="mv-ritem">
    <a class="mv-card" href="/movies/225407/dont-move-2026" data-guid="225407" title="Don&#039;t Move 2026">
    <div class="mv-card__poster"><img class="mv-card__img" src="https://imgsources.cc/./images/cover/30/tt30810705.jpg"></div></a></article>
    <article class="mv-ritem">
    <a class="mv-card" href="/movies/1/no-poster" title="No Poster">
    </a></article>
    """

    @Test func readsTitleYearAndIMDbIDFromEachCard() {
        let titles = MyMovizClient.parse(Self.page)
        #expect(titles.map(\.title) == ["Unit 23 Reloaded", "Don't Move", "No Poster"])
        #expect(titles.map(\.year) == [2024, 2026, nil])
        #expect(titles.map(\.imdbID) == ["tt10303912", "tt30810705", nil], "an id never leaks from the next card")
        #expect(titles.allSatisfy { $0.kind == .movie && $0.source == "MYMOVIZ" })
    }

    @Test func fetchesThePage() async throws {
        let stub = StubTransport { _ in (200, Data(Self.page.utf8)) }
        let titles = try await MyMovizClient(transport: stub).latestMovies()
        #expect(titles.count == 3)
        #expect(stub.requests.first?.url?.absoluteString == "https://mymoviz.co/main/latest-movies")
    }
}
