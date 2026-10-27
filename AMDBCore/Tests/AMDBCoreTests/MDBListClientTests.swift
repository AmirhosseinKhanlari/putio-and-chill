import Foundation
import Testing
@testable import AMDBCore

/// Answers trimmed from api.mdblist.com (October 2026).
@Suite struct MDBListClientTests {
    static let chart = #"""
    {"movies":[
     {"id":950028,"mediatype":"movie","imdb_id":"tt14173636","ids":{"mdblist":"2vwgf","imdb":"tt14173636","tmdb":950028},"title":"The Invite","release_year":2026,"adult":0,"poster":"https://image.tmdb.org/t/p/w200/b7Dr8Chzse8VagexAporUu2RtLx.jpg","rank":1,"rank_change":5},
     {"id":2,"mediatype":"movie","ids":{"tmdb":null},"title":"No TMDB id","release_year":2026,"adult":0,"rank":2},
     {"id":3,"mediatype":"movie","ids":{"tmdb":333},"title":"Adult","release_year":2026,"adult":1,"rank":3},
     {"id":4,"mediatype":"movie","ids":{"tmdb":444},"title":"Disclosure Day","release_year":2026,"adult":0,"poster":null,"rank":4,"rank_change":-2}],
     "shows":[{"id":5,"mediatype":"show","ids":{"tmdb":555},"title":"Crystal Lake","release_year":2026,"adult":0,"rank":1,"rank_change":0}]}
    """#

    @Test func chartKeepsTheKindAskedForWithRankAndMovement() async throws {
        let stub = StubTransport(json: Self.chart)
        let client = MDBListClient(apiKey: "k", transport: stub)
        let movies = try await client.chart(.streamingTop10, kind: .movie)
        #expect(movies.map(\.title) == ["The Invite", "Disclosure Day"])
        #expect(movies[0] == MDBListTitle(tmdbID: 950028, kind: .movie, title: "The Invite", year: 2026,
                                          posterPath: "/b7Dr8Chzse8VagexAporUu2RtLx.jpg", rank: 1, rankChange: 5))
        #expect(movies[1].rankChange == -2 && movies[1].posterPath == nil)
        let shows = try await client.chart(.streamingTop10, kind: .tv)
        #expect(shows.map(\.catalogItem) == [CatalogItem(tmdbID: 555, mediaType: .tv, title: "Crystal Lake", year: 2026)])
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/lists/official/justwatch-streaming-charts/items")
        #expect(request.queryItems["limit"] == "20")
        #expect(request.queryItems["apikey"] == "k")
    }

    @Test func listsKeepPublicOnesWithTheirKind() async throws {
        let stub = StubTransport(json: #"""
        [{"id":2194,"user_id":1230,"user_name":"garycrawfordgc","name":"Latest TV Shows","slug":"latest-tv-shows","description":"","mediatype":"show","items":300,"likes":2878,"private":false},
         {"id":223710,"user_name":"giladg2","name":"Latest Releases","mediatype":"","items":60,"likes":102,"description":null,"private":false},
         {"id":9,"user_name":"x","name":"Hidden","mediatype":"movie","items":3,"private":true}]
        """#)
        let client = MDBListClient(apiKey: "k", transport: stub)
        let lists = try await client.curatedLists()
        #expect(lists == [MDBList(id: 2194, name: "Latest TV Shows", owner: "garycrawfordgc", kind: .tv, count: 300, likes: 2878),
                          MDBList(id: 223710, name: "Latest Releases", owner: "giladg2", kind: nil, count: 60, likes: 102)])
        _ = try await client.popularLists()
        #expect(stub.requests.map(\.url!.path) == ["/lists/curated", "/lists/top"])
    }

    @Test func listItemsComeInPagesInTheListsOrder() async throws {
        let stub = StubTransport(json: #"""
        [{"rank":60,"mediatype":"movie","ids":{"tmdb":1},"title":"Verity","release_year":2026,"adult":0},
         {"rank":59,"mediatype":"show","ids":{"tmdb":2},"title":"Forgotten Island","release_year":2026,"adult":0}]
        """#)
        let client = MDBListClient(apiKey: "k", transport: stub)
        let full = try await client.items(of: 223710, offset: 0, limit: 2)
        #expect(full.titles.map(\.title) == ["Verity", "Forgotten Island"])
        #expect(full.titles.map(\.kind) == [.movie, .tv])
        #expect(full.hasMore)
        #expect(try await client.items(of: 223710, offset: 2, limit: 60).hasMore == false)
        let request = try #require(stub.requests.last)
        #expect(request.url?.path == "/lists/223710/items")
        #expect(request.queryItems["offset"] == "2" && request.queryItems["unified"] == "true")
    }

    @Test func posterPathFromTMDBURL() {
        #expect(MDBListClient.posterPath("https://image.tmdb.org/t/p/w200/abc.jpg") == "/abc.jpg")
        #expect(MDBListClient.posterPath("https://image.tmdb.org/t/p/original/x/y.jpg") == "/x/y.jpg")
        #expect(MDBListClient.posterPath("") == nil)
        #expect(MDBListClient.posterPath(nil) == nil)
    }
}
