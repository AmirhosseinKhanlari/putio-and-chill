import Foundation

/// Which IMDb list to read: someone's watchlist (from their profile or watchlist link) or one of their lists.
public enum IMDbListRef: Equatable, Sendable {
    case watchlist(userID: String)
    /// A watchlist from IMDb's newer profile links (imdb.com/user/p.e4i6…/watchlist), looked up to its user id.
    case profileWatchlist(profileID: String)
    case list(id: String)

    /// From a link or id the user pastes: imdb.com/user/ur123/watchlist, imdb.com/user/p.abc123/watchlist (share
    /// links), imdb.com/user/ur123, ur123, imdb.com/list/ls456, ls456. nil when there's no IMDb user or list in it.
    public static func parse(_ text: String) -> IMDbListRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let list = first(#"\bls\d{5,}\b"#, in: trimmed) { return .list(id: list) }
        if let user = first(#"\bur\d{5,}\b"#, in: trimmed) { return .watchlist(userID: user) }
        if let profile = first(#"(?i)(?<![a-z0-9])p\.[a-z0-9]{8,}"#, in: trimmed) { return .profileWatchlist(profileID: profile.lowercased()) }
        return nil
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(hit.range, in: text) else { return nil }
        return String(text[range])
    }
}

public struct IMDbListTitle: Sendable, Equatable, Codable {
    public let imdbID: String
    public let title: String
    /// IMDb's type: movie, tvSeries, tvMiniSeries, tvMovie, short…
    public let kind: String?
    public let year: Int?

    public init(imdbID: String, title: String, kind: String?, year: Int?) {
        self.imdbID = imdbID; self.title = title; self.kind = kind; self.year = year
    }

    public var isShow: Bool { kind.map { $0.lowercased().hasPrefix("tv") && $0 != "tvMovie" } ?? false }
}

public enum IMDbWatchlistError: Error, Equatable, Sendable {
    /// The list is private (or the user / list doesn't exist): IMDb only shares public lists.
    case privateOrMissing
}

/// Reads a public IMDb watchlist or list (titles in IMDb's order) through IMDb's GraphQL API, which needs no sign-in
/// for public lists. Read-only.
public struct IMDbWatchlistClient: Sendable {
    private let endpoint: URL
    private let http: HTTPRequester

    public init(transport: any HTTPTransport, endpoint: URL = URL(string: "https://api.graphql.imdb.com/")!) {
        self.endpoint = endpoint
        self.http = HTTPRequester(service: "imdb", transport: transport)
    }

    public func titles(_ ref: IMDbListRef, limit: Int = 1000) async throws -> [IMDbListTitle] {
        var ref = ref
        if case let .profileWatchlist(profileID) = ref { ref = .watchlist(userID: try await userID(profileID: profileID)) }
        var titles: [IMDbListTitle] = []
        var cursor: String?
        repeat {
            let page = try await fetch(ref, after: cursor)
            titles += page.items
            cursor = page.hasNext ? page.cursor : nil
        } while cursor != nil && titles.count < limit
        return Array(titles.prefix(limit))
    }

    private func fetch(_ ref: IMDbListRef, after cursor: String?) async throws -> (items: [IMDbListTitle], hasNext: Bool, cursor: String?) {
        let root = switch ref {
        case let .watchlist(userID): #"predefinedList(classType: WATCH_LIST, userId: "\#(Self.clean(userID))")"#
        case let .profileWatchlist(profileID): #"predefinedList(classType: WATCH_LIST, userId: "\#(Self.clean(profileID))")"#
        case let .list(id): #"list(id: "\#(Self.clean(id))")"#
        }
        let after = cursor.map { #", after: "\#($0.replacingOccurrences(of: "\"", with: ""))""# } ?? ""
        let query = """
        { list: \(root) { titleListItemSearch(first: 250\(after)) { total pageInfo { hasNextPage endCursor } \
        edges { listItem: title { id titleText { text } titleType { id } releaseYear { year } } } } } }
        """
        let request = try URLRequest.postJSON(endpoint, body: ["query": query], headers: Self.headers)
        var response = try await http.decode(Response.self, request)
        // IMDb occasionally answers "try again" (SERVICE_UNAVAILABLE): once more before giving up.
        if response.data?.list == nil, response.errors?.contains(where: { $0.extensions?.isRetryable == true }) == true {
            try await Task.sleep(for: .seconds(1))
            response = try await http.decode(Response.self, request)
        }
        guard let search = response.data?.list?.titleListItemSearch else { throw IMDbWatchlistError.privateOrMissing }
        let items = (search.edges ?? []).compactMap { edge -> IMDbListTitle? in
            guard let title = edge.listItem, let text = title.titleText?.text else { return nil }
            return IMDbListTitle(imdbID: title.id, title: text, kind: title.titleType?.id, year: title.releaseYear?.year)
        }
        return (items, search.pageInfo?.hasNextPage ?? false, search.pageInfo?.endCursor)
    }

    /// The "ur…" user id behind a newer "p.…" profile id.
    func userID(profileID: String) async throws -> String {
        let id = profileID.filter { $0.isLetter || $0.isNumber || $0 == "." }
        let request = try URLRequest.postJSON(endpoint, body: ["query": #"{ userProfile(input: {profileId: "\#(id)"}) { userId } }"#],
                                              headers: Self.headers)
        let response = try await http.decode(ProfileResponse.self, request)
        guard let userID = response.data?.userProfile?.userId, !userID.isEmpty else { throw IMDbWatchlistError.privateOrMissing }
        return userID
    }

    private static let headers = [
        "x-imdb-client-name": "imdb-web-next-localized",
        "x-imdb-user-country": "US",
        "x-imdb-user-language": "en-US",
    ]

    struct ProfileResponse: Decodable {
        struct DataBody: Decodable { let userProfile: Profile? }
        struct Profile: Decodable { let userId: String? }
        let data: DataBody?
    }

    private static func clean(_ id: String) -> String { id.filter { $0.isLetter || $0.isNumber } }

    struct Response: Decodable {
        struct DataBody: Decodable { let list: List? }
        struct List: Decodable { let titleListItemSearch: Search? }
        struct Search: Decodable { let total: Int?; let pageInfo: PageInfo?; let edges: [Edge]? }
        struct PageInfo: Decodable { let hasNextPage: Bool?; let endCursor: String? }
        struct Edge: Decodable { let listItem: Title? }
        struct Title: Decodable {
            let id: String
            let titleText: Text?
            let titleType: Kind?
            let releaseYear: Year?
        }
        struct Text: Decodable { let text: String }
        struct Kind: Decodable { let id: String }
        struct Year: Decodable { let year: Int? }
        struct GraphError: Decodable { let extensions: Extensions? }
        struct Extensions: Decodable { let isRetryable: Bool? }
        let data: DataBody?
        let errors: [GraphError]?
    }
}
