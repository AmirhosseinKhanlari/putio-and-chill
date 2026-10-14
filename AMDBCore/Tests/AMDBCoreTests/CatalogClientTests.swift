import Foundation
import Testing
@testable import AMDBCore

@Suite struct CatalogClientTests {
    @Test func searchMultiDecodesAllKinds() async throws {
        let json = #"""
        {"page":1,"results":[
          {"id":693134,"media_type":"movie","title":"Dune: Part Two","overview":"Paul…","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2024-02-27","vote_average":8.2,"genre_ids":[878,12]},
          {"id":95396,"media_type":"tv","name":"Severance","overview":"","poster_path":null,"first_air_date":"2022-02-17","genre_ids":[18]},
          {"id":525,"media_type":"person","name":"Christopher Nolan","profile_path":"/n.jpg","known_for":[{"id":157336,"media_type":"movie","title":"Interstellar","release_date":"2014-11-05"}]}
        ]}
        """#
        let stub = StubTransport(json: json)
        let items = try await CatalogClient(accessToken: "K", transport: stub).searchMulti("dune")
        #expect(items.map(\.mediaType) == [.movie, .tv, .person])
        #expect(items[0].title == "Dune: Part Two")
        #expect(items[0].year == 2024)
        #expect(items[0].genreIDs == [878, 12])
        #expect(items[1].title == "Severance")
        #expect(items[1].year == 2022)
        #expect(items[2].knownFor.first?.title == "Interstellar")
        #expect(items[0].id == "movie-693134")
        let request = try #require(stub.requests.first)
        #expect(request.url?.path == "/3/search/multi")
        #expect(request.queryItems["query"] == "dune")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer K")
    }

    @Test func popularWithoutMediaTypeInfersKind() async throws {
        let stub = StubTransport(json: #"{"results":[{"id":1,"name":"Show","first_air_date":""}]}"#)
        let items = try await CatalogClient(accessToken: "K", transport: stub).popular(.tv)
        #expect(items.first?.mediaType == .tv)
        #expect(items.first?.year == nil)
        #expect(stub.requests.first?.url?.path == "/3/tv/popular")
    }

    @Test func movieDetailExtractsExtras() async throws {
        let json = #"""
        {"id":693134,"title":"Dune: Part Two","overview":"o","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2024-02-27",
         "vote_average":8.2,"runtime":166,"imdb_id":"tt15239678","genres":[{"id":878,"name":"Science Fiction"}],
         "credits":{"cast":[{"name":"Timothée Chalamet","character":"Paul","profile_path":"/t.jpg"}],
                    "crew":[{"name":"Mary Parent","job":"Producer","profile_path":null},
                            {"name":"Denis Villeneuve","job":"Director","profile_path":"/d.jpg"},
                            {"name":"Denis Villeneuve","job":"Screenplay","profile_path":"/d.jpg"},
                            {"name":"Jon Spaihts","job":"Screenplay","profile_path":null},
                            {"name":"Hans Zimmer","job":"Original Music Composer","profile_path":"/h.jpg"}]},
         "videos":{"results":[{"key":"teaser1","site":"YouTube","type":"Teaser"},{"key":"trailer1","site":"YouTube","type":"Trailer"}]},
         "images":{"logos":[{"file_path":"/fr.png","iso_639_1":"fr"},{"file_path":"/en.png","iso_639_1":"en"}]},
         "recommendations":{"results":[{"id":438631,"title":"Dune","release_date":"2021-09-15"}]}}
        """#
        let stub = StubTransport(json: json)
        let detail = try await CatalogClient(accessToken: "K", transport: stub).detail(.movie, id: 693134)
        #expect(detail.imdbID == "tt15239678")
        #expect(detail.runtimeMinutes == 166)
        #expect(detail.genres == ["Science Fiction"])
        #expect(detail.cast.first?.name == "Timothée Chalamet")
        #expect(detail.crew.map(\.name) == ["Denis Villeneuve", "Jon Spaihts", "Hans Zimmer"])
        #expect(detail.crew.map(\.character) == ["Director, Screenplay", "Screenplay", "Composer"])
        #expect(detail.trailerYouTubeKey == "trailer1")
        #expect(detail.logoPath == "/en.png")
        #expect(detail.recommendations.first?.mediaType == .movie)
        #expect(detail.item.year == 2024)
        #expect(stub.requests.first?.queryItems["append_to_response"] == "videos,credits,images,external_ids,recommendations")
    }

    @Test func tvDetailUsesExternalIDsAndSeasons() async throws {
        let json = #"{"id":95396,"name":"Severance","first_air_date":"2022-02-17","episode_run_time":[55],"external_ids":{"imdb_id":"tt11280740"},"created_by":[{"name":"Dan Erickson","profile_path":"/e.jpg"}],"seasons":[{"season_number":0,"name":"Specials","episode_count":2},{"season_number":1,"name":"Season 1","episode_count":9,"poster_path":"/s1.jpg"}]}"#
        let detail = try await CatalogClient(accessToken: "K", transport: StubTransport(json: json)).detail(.tv, id: 95396)
        #expect(detail.imdbID == "tt11280740")
        #expect(detail.runtimeMinutes == 55)
        #expect(detail.crew.first == CastMember(name: "Dan Erickson", character: "Creator", profilePath: "/e.jpg"))
        #expect(detail.seasons.map(\.number) == [1])
        #expect(detail.item.mediaType == .tv)
    }

    @Test func seasonEpisodes() async throws {
        let json = #"{"episodes":[{"episode_number":1,"name":"Good News About Hell","overview":"o","still_path":"/e1.jpg","runtime":57,"air_date":"2022-02-18"}]}"#
        let episodes = try await CatalogClient(accessToken: "K", transport: StubTransport(json: json)).season(tvID: 95396, number: 1)
        #expect(episodes.first?.number == 1)
        #expect(episodes.first?.runtimeMinutes == 57)
    }

    @Test func imageURL() {
        #expect(CatalogClient.imageURL("/p.jpg", size: "w780")?.absoluteString == "https://image.tmdb.org/t/p/w780/p.jpg")
        #expect(CatalogClient.imageURL(nil, size: "w780") == nil)
    }

    @Test func itemFetchesSingleTitle() async throws {
        let stub = StubTransport(json: #"{"id":278,"title":"The Shawshank Redemption","poster_path":"/s.jpg","release_date":"1994-09-23"}"#)
        let item = try await CatalogClient(accessToken: "K", transport: stub).item(.movie, id: 278)
        #expect(item.title == "The Shawshank Redemption")
        #expect(item.mediaType == .movie)
        #expect(item.posterPath == "/s.jpg")
        #expect(stub.requests.first?.url?.path == "/3/movie/278")
    }

    @Test func searchMultiPageReportsTotals() async throws {
        let stub = StubTransport(json: #"{"page":2,"total_pages":7,"results":[{"id":11,"media_type":"movie","title":"Star Wars","release_date":"1977-05-25"}]}"#)
        let page = try await CatalogClient(accessToken: "K", transport: stub).searchMulti("star wars", page: 2)
        #expect(page.items.map(\.title) == ["Star Wars"])
        #expect(page.page == 2)
        #expect(page.totalPages == 7)
        #expect(page.hasMore)
        #expect(stub.requests.first?.queryItems["page"] == "2")
    }

    @Test func personDetailWithCreditsNewestFirst() async throws {
        let json = #"""
        {"id":525,"name":"Christopher Nolan","biography":"British-American filmmaker.","profile_path":"/n.jpg",
         "known_for_department":"Directing","birthday":"1970-07-30","place_of_birth":"London",
         "combined_credits":{"cast":[{"id":1,"media_type":"movie","title":"Cameo","release_date":"2001-01-01","vote_count":5}],
           "crew":[{"id":27205,"media_type":"movie","title":"Inception","release_date":"2010-07-15","job":"Director","vote_count":38000},
                   {"id":27205,"media_type":"movie","title":"Inception","release_date":"2010-07-15","job":"Writer","vote_count":38000},
                   {"id":872585,"media_type":"movie","title":"Oppenheimer","release_date":"2023-07-19","job":"Director","vote_count":9000},
                   {"id":9,"media_type":"movie","title":"Upcoming","release_date":"","job":"Producer","vote_count":0}]}}
        """#
        let stub = StubTransport(json: json)
        let person = try await CatalogClient(accessToken: "K", transport: stub).person(id: 525)
        #expect(person.name == "Christopher Nolan")
        #expect(person.department == "Directing")
        #expect(person.credits.map(\.tmdbID) == [872585, 27205, 1, 9])
        #expect(person.knownFor.first?.tmdbID == 27205)
        #expect(stub.requests.first?.queryItems["append_to_response"] == "combined_credits")
    }

    @Test func collectionPartsInReleaseOrder() async throws {
        let json = #"""
        {"id":10,"name":"Star Wars Collection","overview":"A space saga.","poster_path":"/c.jpg","backdrop_path":"/cb.jpg",
         "parts":[{"id":181808,"title":"The Last Jedi","release_date":"2017-12-13"},
                  {"id":11,"title":"Star Wars","release_date":"1977-05-25"},
                  {"id":1891,"title":"The Empire Strikes Back","release_date":"1980-05-20"},
                  {"id":99,"title":"Untitled","release_date":""}]}
        """#
        let collection = try await CatalogClient(accessToken: "K", transport: StubTransport(json: json)).collection(id: 10)
        #expect(collection.name == "Star Wars Collection")
        #expect(collection.parts.map(\.tmdbID) == [11, 1891, 181808, 99])
    }

    @Test func movieDetailCarriesCollectionAndCastIDs() async throws {
        let json = #"{"id":11,"title":"Star Wars","belongs_to_collection":{"id":10,"name":"Star Wars Collection","poster_path":"/c.jpg","backdrop_path":"/cb.jpg"},"credits":{"cast":[{"id":2,"name":"Mark Hamill","character":"Luke","profile_path":null}]}}"#
        let detail = try await CatalogClient(accessToken: "K", transport: StubTransport(json: json)).detail(.movie, id: 11)
        #expect(detail.collection == CollectionRef(id: 10, name: "Star Wars Collection", posterPath: "/c.jpg", backdropPath: "/cb.jpg"))
        #expect(detail.cast.first?.id == 2)
    }

    @Test func discoverFiltersAndPages() async throws {
        let stub = StubTransport(json: #"{"page":3,"total_pages":40,"results":[{"id":5,"title":"Good Film"}]}"#)
        let page = try await CatalogClient(accessToken: "K", transport: stub)
            .discover(.movie, genreIDs: [35, 18], minRating: 7, minVotes: 500, page: 3)
        #expect(page.items.first?.tmdbID == 5)
        #expect(page.totalPages == 40)
        let q = try #require(stub.requests.first).queryItems
        #expect(q["with_genres"] == "35|18")
        #expect(q["vote_average.gte"] == "7.0")
        #expect(q["vote_count.gte"] == "500")
        #expect(q["page"] == "3")
    }

    @Test func discoverWithAnyFilters() async throws {
        let stub = StubTransport(json: #"{"results":[{"id":7,"name":"Below"}]}"#)
        let items = try await CatalogClient(accessToken: "K", transport: stub)
            .discover(.tv, query: DiscoverQuery(["with_networks": "213", "air_date.gte": "2026-09-13"]))
        #expect(items.map(\.tmdbID) == [7])
        #expect(items.first?.mediaType == .tv)
        let request = try #require(stub.requests.first)
        #expect(request.url?.path.hasSuffix("/discover/tv") == true)
        #expect(request.queryItems["with_networks"] == "213")
        #expect(request.queryItems["air_date.gte"] == "2026-09-13")
        #expect(request.queryItems["include_adult"] == "false")
    }
}
