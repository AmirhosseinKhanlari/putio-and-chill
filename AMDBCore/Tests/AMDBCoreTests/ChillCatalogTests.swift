import Foundation
import Testing
@testable import AMDBCore

@Suite struct ChillCatalogTests {
    /// A fake chill account: GetMovies answers for whatever source was saved last.
    final class Account: @unchecked Sendable {
        let lock = NSLock()
        var source = "MOVIES_SOURCE_YTS"
        var saves: [String] = []
        var failing: Set<String> = []

        func transport() -> StubTransport {
            StubTransport { request in
                let path = request.url!.path
                if path.hasSuffix("/GetUserSettings") {
                    let current = self.lock.withLock { self.source }
                    return (200, Data(#"{"search":{"x":1},"catalog":{"moviesSource":"\#(current)","sort":"CATALOG_SORT_POPULARITY"},"download":{}}"#.utf8))
                }
                if path.hasSuffix("/SaveUserSettings") {
                    let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                    let settings = json["settings"] as! [String: Any]
                    let saved = (settings["catalog"] as! [String: Any])["moviesSource"] as! String
                    #expect(settings["search"] != nil, "the rest of the settings is sent back untouched")
                    self.lock.withLock { self.source = saved; self.saves.append(saved) }
                    return (200, Data("{}".utf8))
                }
                if path.hasSuffix("/GetMovies") {
                    let current = self.lock.withLock { self.source }
                    if self.failing.contains(current) { return (503, Data()) }
                    let movies: String = switch current {
                    case "MOVIES_SOURCE_YTS": #"[{"id":"tt15239678","title":"Dune: Part Two","year":2024,"releaseDate":"2024-03-01"},{"id":"y2","title":"Heat","year":1995}]"#
                    case "MOVIES_SOURCE_ROTTEN_TOMATOES": #"[{"id":"rt1","title":"Anora","year":2024,"releaseDate":"2024-10-18","externalUrl":"https://www.imdb.com/title/tt28607951/"}]"#
                    case "MOVIES_SOURCE_TRAKT": #"[{"id":"tr","title":"Dune: Part Two","year":2024,"externalUrl":"https://imdb.com/title/tt15239678"}]"#
                    default: "[]"
                    }
                    return (200, Data(#"{"source":"\#(current)","movies":\#(movies)}"#.utf8))
                }
                if path.hasSuffix("/GetTVShows") {
                    #expect(request.bodyString.contains("TV_SHOWS_SOURCE_ALL_PROVIDERS"))
                    return (200, Data(#"{"shows":[{"imdbId":"tt0903747","title":"Breaking Bad","year":2008,"firstAirDate":"2008-01-20"},{"imdbId":"tt11280740","title":"Severance","year":2022,"firstAirDate":"2022-02-18"}]}"#.utf8))
                }
                return (404, Data())
            }
        }
    }

    @Test func combinesEveryMovieListAndRestoresTheUsersChoice() async throws {
        let account = Account()
        let movies = try await ChillCatalogClient(token: "tok", transport: account.transport()).combinedMovies()

        #expect(movies.map(\.title) == ["Anora", "Dune: Part Two", "Heat"], "newest first, Dune only once")
        #expect(movies.first?.imdbID == "tt28607951")
        #expect(account.saves.dropLast() == ChillMerge.movieSources[...])
        #expect(account.saves.last == "MOVIES_SOURCE_YTS", "the user's own pick is put back")
        #expect(account.source == "MOVIES_SOURCE_YTS")
    }

    @Test func restoresEvenWhenAListFails() async throws {
        let account = Account()
        account.failing = ["MOVIES_SOURCE_TRAKT", "MOVIES_SOURCE_ROTTEN_TOMATOES"]
        let movies = try await ChillCatalogClient(token: "tok", transport: account.transport()).combinedMovies()
        #expect(movies.map(\.title) == ["Dune: Part Two", "Heat"])
        #expect(account.source == "MOVIES_SOURCE_YTS")
    }

    @Test func showsComeFromAllProvidersNewestFirst() async throws {
        let shows = try await ChillCatalogClient(token: "tok", transport: Account().transport()).combinedShows()
        #expect(shows.map(\.title) == ["Severance", "Breaking Bad"])
        #expect(shows.allSatisfy { $0.kind == .tv })
    }
}
