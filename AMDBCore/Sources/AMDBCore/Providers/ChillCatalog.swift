import Foundation

/// A movie or show from one of chill.institute's lists (Rotten Tomatoes, IMDb Moviemeter, YTS, Trakt, IMDb Top 250,
/// or the streaming services).
public struct ChillTitle: Sendable, Hashable, Codable {
    public let imdbID: String?
    public let title: String
    public let year: Int?
    public let kind: MediaKind
    /// YYYY-MM-DD when known.
    public let releaseDate: String?
    public let overview: String?
    public let rating: Double?
    public let source: String

    public init(imdbID: String?, title: String, year: Int?, kind: MediaKind, releaseDate: String? = nil,
                overview: String? = nil, rating: Double? = nil, source: String) {
        self.imdbID = imdbID; self.title = title; self.year = year; self.kind = kind; self.releaseDate = releaseDate
        self.overview = overview; self.rating = rating; self.source = source
    }

    /// Same title across lists: IMDb id when there is one, else title and year.
    public var mergeKey: String { imdbID ?? "\(title.lowercased())|\(year ?? 0)" }
}

public protocol ChillCatalogService: Sendable {
    /// Every movie list chill offers, merged into one, newest first. `allowSettingsSwitch: false` never touches the
    /// account's saved movie source (the fallback when the RSS feeds can't be read); it throws instead.
    func combinedMovies(allowSettingsSwitch: Bool) async throws -> [ChillTitle]
    /// chill's "All providers" TV list (already combined across streaming services), newest first.
    func combinedShows() async throws -> [ChillTitle]
}

extension ChillCatalogService {
    public func combinedMovies() async throws -> [ChillTitle] { try await combinedMovies(allowSettingsSwitch: true) }
}

public enum ChillMerge {
    public static let movieSources = ["MOVIES_SOURCE_ROTTEN_TOMATOES", "MOVIES_SOURCE_IMDB_MOVIEMETER", "MOVIES_SOURCE_YTS",
                                      "MOVIES_SOURCE_TRAKT", "MOVIES_SOURCE_IMDB_TOP_250"]

    /// One list: duplicates dropped (first source wins), newest release first, undated titles after, in list order.
    public static func combine(_ lists: [[ChillTitle]]) -> [ChillTitle] {
        var seen: Set<String> = []
        var merged: [ChillTitle] = []
        // Round-robin so each list's top picks come before any list's tail.
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                if seen.insert(list[index].mergeKey).inserted { merged.append(list[index]) }
            }
        }
        return merged.enumerated().sorted { a, b in
            switch (date(a.element), date(b.element)) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// A title with only a year counts as late that year, so lists without exact dates (MyMoviz, RSS) mix in by
    /// year instead of always sinking below dated ones.
    private static func date(_ title: ChillTitle) -> String? {
        if let date = title.releaseDate, !date.isEmpty { return date }
        return title.year.map { "\($0)-12-31" }
    }

    /// "tt1234567" from an id or an IMDb link.
    static func imdbID(in values: String?...) -> String? {
        for value in values.compactMap({ $0 }) {
            if let range = value.range(of: #"tt\d{5,}"#, options: .regularExpression) { return String(value[range]) }
        }
        return nil
    }
}

/// chill.institute's catalog lists, with the user's chill token.
///
/// Movie lists come from chill's per-source RSS feeds (`/rss/movies/<source>?auth_token=…`), which don't touch the
/// account. If a feed can't be read, it falls back to the API, which only serves the list chosen in the account's
/// settings: it saves each choice in turn, then always puts the user's own choice back.
public actor ChillCatalogClient: ChillCatalogService {
    private let token: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(token: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.chill.institute/v4")!) {
        self.token = token
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "chill", transport: transport)
    }

    public func combinedMovies(allowSettingsSwitch: Bool) async throws -> [ChillTitle] {
        do {
            return ChillMerge.combine(try await rssLists())
        } catch {
            guard allowSettingsSwitch else { throw error }
            return try await switchingSettings()
        }
    }

    static let rssPaths: [String: String] = [
        "MOVIES_SOURCE_ROTTEN_TOMATOES": "rotten-tomatoes", "MOVIES_SOURCE_IMDB_MOVIEMETER": "imdb/moviemeter",
        "MOVIES_SOURCE_YTS": "yts", "MOVIES_SOURCE_TRAKT": "trakt", "MOVIES_SOURCE_IMDB_TOP_250": "imdb/top-250",
    ]

    /// Every movie list from its RSS feed; nil-ish (throws) when any feed is missing or empty, so the caller falls back.
    private func rssLists() async throws -> [[ChillTitle]] {
        let root = baseURL.deletingLastPathComponent()
        var lists: [[ChillTitle]] = []
        for source in ChillMerge.movieSources {
            guard let path = Self.rssPaths[source],
                  var components = URLComponents(url: root.appending(path: "rss/movies/\(path)"), resolvingAgainstBaseURL: false)
            else { throw AppError.decoding(service: "chill", detail: "rss path") }
            components.queryItems = [URLQueryItem(name: "auth_token", value: token)]
            guard let url = components.url else { throw AppError.decoding(service: "chill", detail: "rss url") }
            let data = try await http.data(.get(url, headers: ["Accept": "application/rss+xml, application/xml, text/xml"]))
            let titles = ChillRSS.parse(data, source: source)
            guard !titles.isEmpty else { throw AppError.decoding(service: "chill", detail: "empty rss") }
            lists.append(titles)
        }
        return lists
    }

    private func switchingSettings() async throws -> [ChillTitle] {
        let original = try await raw("GetUserSettings", body: Data("{}".utf8))
        guard var settings = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw AppError.decoding(service: "chill", detail: "settings")
        }
        var catalog = settings["catalog"] as? [String: Any] ?? [:]
        var lists: [[ChillTitle]] = []
        var failure: (any Error)?
        for source in ChillMerge.movieSources {
            do {
                catalog["moviesSource"] = source
                settings["catalog"] = catalog
                _ = try await raw("SaveUserSettings", body: JSONSerialization.data(withJSONObject: ["settings": settings]))
                let response = try await decode(MoviesResponse.self, "GetMovies", body: Data("{}".utf8))
                lists.append((response.movies ?? []).map { $0.title(source: source) })
            } catch {
                failure = error
            }
        }
        // Always restore what the user had picked on chill.institute (even after a failure above).
        if let restored = try? JSONSerialization.jsonObject(with: original) as? [String: Any] {
            _ = try? await raw("SaveUserSettings", body: JSONSerialization.data(withJSONObject: ["settings": restored]))
        }
        if lists.allSatisfy(\.isEmpty), let failure { throw failure }
        return ChillMerge.combine(lists)
    }

    public func combinedShows() async throws -> [ChillTitle] {
        let body = Data(#"{"source":"TV_SHOWS_SOURCE_ALL_PROVIDERS"}"#.utf8)
        let response = try await decode(ShowsResponse.self, "GetTVShows", body: body)
        return ChillMerge.combine([(response.shows ?? []).map(\.chillTitle)])
    }

    // MARK: Wire

    private func raw(_ method: String, body: Data) async throws -> Data {
        try await http.data(request(method, body: body))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ method: String, body: Data) async throws -> T {
        try await http.decode(type, request(method, body: body))
    }

    private func request(_ method: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "chill.v4.UserService/\(method)"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }

    struct MoviesResponse: Decodable { let movies: [Movie]? }
    struct ShowsResponse: Decodable { let shows: [Show]? }

    struct Movie: Decodable {
        let id: String?
        let title: String?
        let titlePretty: String?
        let year: Int?
        let externalUrl: String?
        let releaseDate: String?
        let overview: String?
        let rating: Double?

        func title(source: String) -> ChillTitle {
            ChillTitle(imdbID: ChillMerge.imdbID(in: id, externalUrl), title: titlePretty.flatMap { $0.isEmpty ? nil : $0 } ?? title ?? "",
                       year: year == 0 ? nil : year, kind: .movie, releaseDate: releaseDate, overview: overview,
                       rating: rating, source: source)
        }
    }

    struct Show: Decodable {
        let imdbId: String?
        let title: String?
        let year: Int?
        let firstAirDate: String?
        let overview: String?
        let rating: Double?
        let source: String?

        var chillTitle: ChillTitle {
            ChillTitle(imdbID: ChillMerge.imdbID(in: imdbId), title: title ?? "", year: year == 0 ? nil : year, kind: .tv,
                       releaseDate: firstAirDate, overview: overview, rating: rating, source: source ?? "TV_SHOWS_SOURCE_ALL_PROVIDERS")
        }
    }
}

/// Reads a chill movie RSS feed: each item's title (a movie or release name) and any IMDb id in the item.
/// Several releases of one movie collapse into one title.
enum ChillRSS {
    static func parse(_ data: Data, source: String) -> [ChillTitle] {
        let reader = ItemReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        var seen: Set<String> = []
        return reader.items.compactMap { item -> ChillTitle? in
            let parsed = ReleaseNameParser.parse(item.title)
            let name = parsed.title.isEmpty ? item.title : parsed.title
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let title = ChillTitle(imdbID: ChillMerge.imdbID(in: item.text), title: name, year: parsed.year, kind: .movie,
                                   source: source)
            return seen.insert(title.mergeKey).inserted ? title : nil
        }
    }

    final class ItemReader: NSObject, XMLParserDelegate {
        struct Item { var title = ""; var text = "" }
        var items: [Item] = []
        private var current: Item?
        private var element = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            element = name
            if name == "item" || name == "entry" { current = Item() }
            if current != nil { current?.text += " " + attributes.values.joined(separator: " ") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

        func parser(_ parser: XMLParser, foundCDATA block: Data) { append(String(decoding: block, as: UTF8.self)) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item" || name == "entry", let current { items.append(current); self.current = nil }
            element = ""
        }

        private func append(_ string: String) {
            guard current != nil else { return }
            if element == "title" { current?.title += string }
            current?.text += " " + string
        }
    }
}
