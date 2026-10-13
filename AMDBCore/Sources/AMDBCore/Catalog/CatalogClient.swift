import Foundation

public struct CatalogClient: Sendable {
    private let accessToken: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(accessToken: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
        self.accessToken = accessToken
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "tmdb", transport: transport)
    }

    public static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }

    public func validate() async throws {
        _ = try await http.data(request("configuration"))
    }

    public func searchMulti(_ query: String) async throws -> [CatalogItem] {
        try await page("search/multi", [("query", query), ("include_adult", "false")])
    }

    public func trending(_ kind: MediaKind?) async throws -> [CatalogItem] {
        try await page("trending/\(kind?.rawValue ?? "all")/week")
    }

    public func popular(_ kind: MediaKind) async throws -> [CatalogItem] { try await page("\(kind.rawValue)/popular") }
    public func topRated(_ kind: MediaKind) async throws -> [CatalogItem] { try await page("\(kind.rawValue)/top_rated") }

    public func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem] {
        try await page("discover/\(kind.rawValue)", [("with_genres", String(genreID)), ("sort_by", "popularity.desc")])
    }

    public func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] {
        try await page("search/movie", [("query", title)] + (year.map { [("year", String($0))] } ?? []))
    }

    public func searchTV(title: String, year: Int?) async throws -> [CatalogItem] {
        try await page("search/tv", [("query", title)] + (year.map { [("first_air_date_year", String($0))] } ?? []))
    }

    public func findByIMDb(_ imdbID: String) async throws -> CatalogItem? {
        struct Found: Decodable { let movieResults: [CatalogItem]?; let tvResults: [CatalogItem]? }
        let found = try await http.decode(Found.self, request("find/\(imdbID)", [("external_source", "imdb_id")]), decoder: .snakeCase)
        return found.movieResults?.first ?? found.tvResults?.first
    }

    public func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail {
        let req = request("\(kind.rawValue)/\(id)", [
            ("append_to_response", "videos,credits,images,external_ids,recommendations"),
            ("include_image_language", "en,null"),
        ])
        let body = try await http.data(req)
        do {
            let decoder = JSONDecoder.snakeCase
            let item = try decoder.decode(CatalogItem.self, from: body)
            let raw = try decoder.decode(DetailRaw.self, from: body)
            return TitleDetail(
                item: item,
                imdbID: raw.imdbId ?? raw.externalIds?.imdbId,
                runtimeMinutes: raw.runtime ?? raw.episodeRunTime?.first,
                genres: raw.genres?.map(\.name) ?? [],
                cast: (raw.credits?.cast ?? []).prefix(20).map { CastMember(name: $0.name, character: $0.character, profilePath: $0.profilePath) },
                crew: raw.keyCrew,
                trailerYouTubeKey: raw.videos?.results?.first { $0.site == "YouTube" && $0.type == "Trailer" }?.key,
                logoPath: raw.images?.logos?.first { $0.iso6391 == "en" }?.filePath ?? raw.images?.logos?.first?.filePath,
                recommendations: raw.recommendations?.results ?? [],
                seasons: (raw.seasons ?? []).filter { $0.seasonNumber > 0 }.map {
                    SeasonSummary(number: $0.seasonNumber, name: $0.name ?? "Season \($0.seasonNumber)",
                                  episodeCount: $0.episodeCount ?? 0, posterPath: $0.posterPath)
                })
        } catch {
            throw AppError.decoding(service: "tmdb", detail: String(describing: error))
        }
    }

    /// Light single-title lookup (no credits/videos), used to show chart posters.
    public func item(_ kind: MediaKind, id: Int) async throws -> CatalogItem {
        try await http.decode(CatalogItem.self, request("\(kind.rawValue)/\(id)"), decoder: .snakeCase)
    }

    public func season(tvID: Int, number: Int) async throws -> [Episode] {
        let raw = try await http.decode(SeasonRaw.self, request("tv/\(tvID)/season/\(number)"), decoder: .snakeCase)
        return (raw.episodes ?? []).map {
            Episode(number: $0.episodeNumber, name: $0.name ?? "Episode \($0.episodeNumber)", overview: $0.overview ?? "",
                    stillPath: $0.stillPath, runtimeMinutes: $0.runtime, airDate: $0.airDate)
        }
    }

    private func request(_ path: String, _ query: [(String, String)] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = ([("language", "en-US")] + query).map { URLQueryItem(name: $0.0, value: $0.1) }
        return .get(components.url!, headers: ["Authorization": "Bearer \(accessToken)"])
    }

    private func page(_ path: String, _ query: [(String, String)] = []) async throws -> [CatalogItem] {
        struct Page: Decodable { let results: [CatalogItem] }
        return try await http.decode(Page.self, request(path, query), decoder: .snakeCase).results
    }
}
