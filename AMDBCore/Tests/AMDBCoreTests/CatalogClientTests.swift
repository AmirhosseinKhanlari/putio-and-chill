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
}
