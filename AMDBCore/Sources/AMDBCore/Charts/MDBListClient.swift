import Foundation

/// An MDBList chart (mdblist.com/lists/official): each comes as a movie and a show list, ranked, with how far each
/// title moved since the last update.
public enum MDBListChart: String, CaseIterable, Sendable, Hashable {
    case streamingTop10 = "justwatch-streaming-charts"
    case trending
    case mostWatchedWeek = "most-watched-week"
    case anticipated
    case popular
    case moviemeter
    case mostWatched = "most-watched"
    case streamingCharts = "streaming-charts"

    public var title: String {
        switch self {
        case .streamingTop10: "Top 10 on Streaming Today"
        case .trending: "Trending"
        case .mostWatchedWeek: "Most Watched This Week"
        case .anticipated: "Most Anticipated"
        case .popular: "Popular"
        case .moviemeter: "IMDb MovieMeter"
        case .mostWatched: "Most Watched This Year"
        case .streamingCharts: "Streaming Charts"
        }
    }

    /// Where it comes from, said under the row.
    public var credit: String { self == .streamingTop10 ? "Daily US chart from JustWatch, via MDBList" : "From MDBList" }

    /// Titles per kind: the Top 10 is ten, the others as many as MDBList has (up to 100).
    public var size: Int { self == .streamingTop10 ? 10 : 100 }
}

/// A list on MDBList (Popular Lists, Curated Lists).
public struct MDBList: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    /// MDBList user name of whoever made it.
    public let owner: String
    /// nil: movies and shows.
    public let kind: MediaKind?
    public let count: Int
    public let likes: Int?
    public let summary: String?

    public init(id: Int, name: String, owner: String, kind: MediaKind?, count: Int, likes: Int? = nil, summary: String? = nil) {
        self.id = id; self.name = name; self.owner = owner; self.kind = kind; self.count = count; self.likes = likes
        self.summary = summary
    }
}

/// A title on an MDBList chart or list, with what a poster needs.
public struct MDBListTitle: Sendable, Hashable, Identifiable {
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public let year: Int?
    /// TMDB poster path ("/abc.jpg").
    public let posterPath: String?
    public let rank: Int?
    /// Places moved up (positive) or down since the chart's last update.
    public let rankChange: Int?

    public init(tmdbID: Int, kind: MediaKind, title: String, year: Int? = nil, posterPath: String? = nil, rank: Int? = nil,
                rankChange: Int? = nil) {
        self.tmdbID = tmdbID; self.kind = kind; self.title = title; self.year = year; self.posterPath = posterPath
        self.rank = rank; self.rankChange = rankChange
    }

    public var id: String { "\(kind.rawValue)-\(tmdbID)" }
    public var catalogItem: CatalogItem { CatalogItem(tmdbID: tmdbID, mediaType: kind, title: title, posterPath: posterPath, year: year) }
}

/// One page of a list's titles.
public struct MDBListPage: Sendable, Equatable {
    public let titles: [MDBListTitle]
    public let hasMore: Bool
    public init(titles: [MDBListTitle], hasMore: Bool) { self.titles = titles; self.hasMore = hasMore }
}

/// MDBList's charts and lists (`https://api.mdblist.com`, same key as ratings). Titles without a TMDB id, and adult
/// titles, are left out.
public struct MDBListClient: Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(apiKey: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.mdblist.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "mdblist", transport: transport)
    }

    /// `GET /lists/official/{chart}/items`: movies and shows come together, so twice the size is asked for.
    public func chart(_ chart: MDBListChart, kind: MediaKind) async throws -> [MDBListTitle] {
        let get = request("lists/official/\(chart.rawValue)/items", ["limit": "\(chart.size * 2)", "append_to_response": "poster"])
        let response = try await http.decode(Items.self, get, decoder: .snakeCase)
        let rows = (kind == .tv ? response.shows : response.movies) ?? []
        // Some charts count from 0 (Most Watched This Week); every chart shows #1 first.
        let shift = rows.contains { $0.rank == 0 } ? 1 : 0
        return Array(rows.compactMap(\.parsed).prefix(chart.size)).map { title in
            MDBListTitle(tmdbID: title.tmdbID, kind: title.kind, title: title.title, year: title.year, posterPath: title.posterPath,
                         rank: title.rank.map { $0 + shift }, rankChange: title.rankChange)
        }
    }

    /// `GET /lists/top`: the most liked lists.
    public func popularLists() async throws -> [MDBList] {
        try await http.decode([ListInfo].self, request("lists/top", [:]), decoder: .snakeCase).compactMap(\.list)
    }

    /// `GET /lists/curated`: the lists MDBList picks.
    public func curatedLists() async throws -> [MDBList] {
        try await http.decode([ListInfo].self, request("lists/curated", [:]), decoder: .snakeCase).compactMap(\.list)
    }

    /// `GET /lists/{id}/items`, movies and shows in the list's own order, `limit` at a time.
    public func items(of list: Int, offset: Int = 0, limit: Int = 60) async throws -> MDBListPage {
        let rows = try await http.decode([Item].self, request("lists/\(list)/items", [
            "limit": "\(limit)", "offset": "\(offset)", "unified": "true", "append_to_response": "poster",
        ]), decoder: .snakeCase)
        return MDBListPage(titles: rows.compactMap(\.parsed), hasMore: rows.count >= limit)
    }

    private func request(_ path: String, _ query: [String: String]) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "apikey", value: apiKey)]
        return .get(components.url!)
    }

    struct Items: Decodable {
        let movies: [Item]?
        let shows: [Item]?
    }

    struct Item: Decodable {
        let mediatype: String?
        let title: String?
        let releaseYear: Int?
        let poster: String?
        let rank: Int?
        let rankChange: Int?
        let adult: Int?
        let ids: IDs?
        struct IDs: Decodable { let tmdb: Int? }

        /// nil without a TMDB id or a known kind, and for adult titles.
        var parsed: MDBListTitle? {
            guard adult != 1, let tmdb = ids?.tmdb, tmdb > 0, let kind = MDBListClient.kind(mediatype) else { return nil }
            return MDBListTitle(tmdbID: tmdb, kind: kind, title: title ?? "", year: releaseYear,
                                posterPath: MDBListClient.posterPath(poster), rank: rank, rankChange: rankChange)
        }
    }

    struct ListInfo: Decodable {
        let id: Int?
        let name: String?
        let userName: String?
        let mediatype: String?
        let items: Int?
        let likes: Int?
        let description: String?
        let `private`: Bool?

        var list: MDBList? {
            guard let id, let name, !name.isEmpty, `private` != true else { return nil }
            let summary = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MDBList(id: id, name: name, owner: userName ?? "", kind: MDBListClient.kind(mediatype), count: items ?? 0,
                           likes: likes, summary: summary?.isEmpty == false ? summary : nil)
        }
    }

    static func kind(_ mediatype: String?) -> MediaKind? {
        switch mediatype {
        case "movie": .movie
        case "show": .tv
        default: nil
        }
    }

    /// "https://image.tmdb.org/t/p/w200/abc.jpg" → "/abc.jpg": posters are drawn at the size each screen needs.
    static func posterPath(_ url: String?) -> String? {
        guard let url, let range = url.range(of: #"/t/p/[^/]+(/.+)$"#, options: .regularExpression) else { return nil }
        return String(url[range]).replacingOccurrences(of: #"^/t/p/[^/]+"#, with: "", options: .regularExpression)
    }
}
