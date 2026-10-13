import Foundation

/// One ranked title from a chart.
public struct ChartEntry: Sendable, Hashable, Identifiable {
    public let rank: Int
    public let kind: MediaKind
    public let title: String
    public let year: Int?
    public let imdbID: String?
    public let tmdbID: Int?

    public init(rank: Int, kind: MediaKind, title: String, year: Int?, imdbID: String?, tmdbID: Int?) {
        self.rank = rank; self.kind = kind; self.title = title; self.year = year; self.imdbID = imdbID; self.tmdbID = tmdbID
    }

    public var id: String { "\(kind.rawValue)-\(rank)-\(imdbID ?? title)" }
}

/// IMDb charts, read from Trakt's long-running public mirror lists (IMDb blocks direct access).
public struct IMDbChart: Sendable, Hashable {
    public let user: String
    public let list: String
    public let kind: MediaKind
    public let title: String

    public static let top250Movies = IMDbChart(user: "justin", list: "imdb-top-rated-movies", kind: .movie, title: "IMDb Top 250 Movies")
    public static let top250TV = IMDbChart(user: "justin", list: "imdb-top-rated-tv-shows", kind: .tv, title: "IMDb Top 250 TV")
}

/// Trakt API v2: `GET /users/{user}/lists/{list}/items` with `trakt-api-key: <client id>`.
public struct TraktClient: Sendable {
    private let clientID: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(clientID: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.trakt.tv")!) {
        self.clientID = clientID
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "trakt", transport: transport)
    }

    public func listItems(user: String, list: String) async throws -> [ChartEntry] {
        let url = baseURL.appending(path: "users/\(user)/lists/\(list)/items")
        let request = URLRequest.get(url, headers: ["trakt-api-key": clientID, "trakt-api-version": "2",
                                                    "Content-Type": "application/json"])
        let items = try await http.decode([Item].self, request, decoder: .snakeCase)
        return items.compactMap { item -> ChartEntry? in
            switch item.type {
            case "movie": return item.movie.map { $0.entry(rank: item.rank, kind: .movie) }
            case "show": return item.show.map { $0.entry(rank: item.rank, kind: .tv) }
            default: return nil
            }
        }
    }

    public func chart(_ chart: IMDbChart) async throws -> [ChartEntry] {
        try await listItems(user: chart.user, list: chart.list)
    }

    struct Item: Decodable {
        let rank: Int
        let type: String
        let movie: Media?
        let show: Media?
    }

    struct Media: Decodable {
        struct IDs: Decodable { let imdb: String?; let tmdb: Int? }
        let title: String
        let year: Int?
        let ids: IDs

        func entry(rank: Int, kind: MediaKind) -> ChartEntry {
            ChartEntry(rank: rank, kind: kind, title: title, year: year, imdbID: ids.imdb, tmdbID: ids.tmdb)
        }
    }
}
