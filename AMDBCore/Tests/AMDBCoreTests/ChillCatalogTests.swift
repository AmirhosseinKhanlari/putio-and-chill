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
        /// Runs after each save of a movie source (to cancel the request at a chosen moment).
        var onSave: (@Sendable (String) -> Void)?

        func transport() -> StubTransport {
            StubTransport { request in
                // Like URLSession: a request from a cancelled task fails at once.
                if Task.isCancelled { throw URLError(.cancelled) }
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
                    self.lock.withLock { self.onSave }?(saved)
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

    /// The screen moves on while the lists are being read (the request is cancelled right after the first source was
    /// saved): the remaining sources are skipped, and the user's own choice still goes back, once.
    @Test func restoresTheUsersChoiceWhenCancelledMidway() async throws {
        let account = Account()
        let client = ChillCatalogClient(token: "tok", transport: account.transport())
        // The save runs inside the request's own task: cancelling that is what the screen going away does.
        account.onSave = { saved in if saved == ChillMerge.movieSources[0] { withUnsafeCurrentTask { $0?.cancel() } } }
        let request = Task { try await client.combinedMovies() }
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(account.saves == [ChillMerge.movieSources[0], "MOVIES_SOURCE_YTS"], "one switch, then the restore")
        #expect(account.source == "MOVIES_SOURCE_YTS")
    }

    /// RSS feeds (one per source, token in the URL) are used first, so the account's settings are never touched.
    @Test func readsRSSFeedsWithoutChangingSettings() async throws {
        let rss: @Sendable (String, String) -> Data = { title, imdb in Data("""
            <?xml version="1.0"?><rss version="2.0"><channel><title>chill</title>
            <item><title>\(title)</title><link>magnet:?xt=urn:btih:aaaa</link><guid>https://www.imdb.com/title/\(imdb)/</guid></item>
            <item><title><![CDATA[\(title).1080p.WEBRip]]></title><description>\(imdb)</description></item>
            </channel></rss>
            """.utf8) }
        let stub = StubTransport { request in
            let path = request.url!.path
            #expect(!path.hasSuffix("/SaveUserSettings"))
            switch path {
            case "/rss/movies/yts": return (200, rss("Heat (1995)", "tt0113277"))
            case "/rss/movies/rotten-tomatoes": return (200, rss("Anora 2024", "tt28607951"))
            case "/rss/movies/trakt", "/rss/movies/imdb/moviemeter", "/rss/movies/imdb/top-250": return (200, rss("Anora 2024", "tt28607951"))
            default: return (404, Data())
            }
        }
        let movies = try await ChillCatalogClient(token: "tok", transport: stub).combinedMovies()
        #expect(movies.map(\.title) == ["Anora", "Heat"])
        #expect(movies.map(\.imdbID) == ["tt28607951", "tt0113277"])
        #expect(stub.requests.allSatisfy { $0.url!.query == "auth_token=tok" })
    }

    @Test func showsComeFromAllProvidersNewestFirst() async throws {
        let shows = try await ChillCatalogClient(token: "tok", transport: Account().transport()).combinedShows()
        #expect(shows.map(\.title) == ["Severance", "Breaking Bad"])
        #expect(shows.allSatisfy { $0.kind == .tv })
    }
}
