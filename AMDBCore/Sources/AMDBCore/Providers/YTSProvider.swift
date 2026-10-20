import Foundation

public struct YTSProvider: SourceProvider {
    public let id = "yts"
    private let baseURL: URL
    private let http: HTTPRequester

    public init(baseURL: URL = URL(string: "https://movies-api.accel.li")!, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "yts", transport: transport)
    }

    public func releases(for query: MediaQuery) async throws -> [Release] {
        guard case let .movie(_, title, year) = query else { return [] }
        // By IMDb id when there is one; otherwise by title, keeping only movies with that title (and year, ±1).
        let term = query.imdbID ?? MediaQuery.searchTitle(title)
        guard !term.isEmpty else { return [] }
        var components = URLComponents(url: baseURL.appending(path: "api/v2/list_movies.json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query_term", value: term), URLQueryItem(name: "limit", value: query.imdbID == nil ? "20" : "5")]
        let response = try await http.decode(Response.self, .get(components.url!), decoder: .snakeCase)
        let movies = (response.data?.movies ?? []).filter { movie in
            guard query.imdbID == nil else { return true }
            let yearFits = year.map { abs($0 - movie.year) <= 1 } ?? true
            return yearFits && ReleaseRelevance.words(movie.title).joined() == ReleaseRelevance.words(title).joined()
        }
        return movies.flatMap { movie in
            (movie.torrents ?? []).compactMap { torrent -> Release? in
                guard let hash = Magnet.normalize(torrent.hash) else { return nil }
                let kind = (torrent.type ?? "web").uppercased()
                let name = "\(movie.title) (\(movie.year)) [\(torrent.quality)] [\(kind)] [YTS]"
                var parsed = ReleaseNameParser.parse(name)
                parsed.title = movie.title
                parsed.codec = torrent.videoCodec?.lowercased() == "x265" ? "H.265" : "H.264"
                return Release(name: name, link: Magnet.make(infoHash: hash, name: movie.title), infoHash: hash,
                               sizeBytes: torrent.sizeBytes, seeders: torrent.seeds,
                               sources: [SourceTag(.direct, "YTS")], parsed: parsed)
            }
        }
    }

    struct Response: Decodable {
        let data: Body?
        struct Body: Decodable { let movies: [Movie]? }
        struct Movie: Decodable { let title: String; let year: Int; let torrents: [Torrent]? }
        struct Torrent: Decodable {
            let hash: String
            let quality: String
            let type: String?
            let videoCodec: String?
            let seeds: Int?
            let sizeBytes: Int64?
        }
    }
}
