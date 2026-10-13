import Foundation

/// One episode's IMDb score.
public struct EpisodeRating: Sendable, Hashable {
    public let rating: Double
    public let votes: Int

    public init(rating: Double, votes: Int) { self.rating = rating; self.votes = votes }
}

/// Per-episode IMDb ratings for a season, from the same GraphQL API imdb.com uses (one request per season).
/// Unofficial: on any failure callers simply show no episode scores.
public struct IMDbEpisodeRatingsClient: Sendable {
    private let endpoint: URL
    private let http: HTTPRequester

    public init(transport: any HTTPTransport, endpoint: URL = URL(string: "https://caching.graphql.imdb.com/")!) {
        self.endpoint = endpoint
        self.http = HTTPRequester(service: "imdb", transport: transport)
    }

    /// Episode number → rating, for episodes IMDb has rated.
    public func ratings(seriesIMDbID: String, season: Int) async throws -> [Int: EpisodeRating] {
        let id = seriesIMDbID.filter { $0.isLetter || $0.isNumber }
        let query = """
        { title(id: "\(id)") { episodes { episodes(first: 250, filter: {includeSeasons: ["\(season)"]}) { edges { node { \
        series { displayableEpisodeNumber { episodeNumber { text } } } ratingsSummary { aggregateRating voteCount } } } } } } }
        """
        let request = try URLRequest.postJSON(endpoint, body: ["query": query], headers: [
            "x-imdb-client-name": "imdb-web-next-localized",
            "x-imdb-user-country": "US",
            "x-imdb-user-language": "en-US",
        ])
        let response = try await http.decode(Response.self, request)
        var result: [Int: EpisodeRating] = [:]
        for node in response.data?.title?.episodes?.episodes?.edges?.compactMap(\.node) ?? [] {
            guard let text = node.series?.displayableEpisodeNumber?.episodeNumber?.text, let number = Int(text),
                  let rating = node.ratingsSummary?.aggregateRating, rating > 0 else { continue }
            result[number] = EpisodeRating(rating: rating, votes: node.ratingsSummary?.voteCount ?? 0)
        }
        return result
    }

    struct Response: Decodable {
        struct DataBody: Decodable { let title: Title? }
        struct Title: Decodable { let episodes: Episodes? }
        struct Episodes: Decodable { let episodes: Connection? }
        struct Connection: Decodable { let edges: [Edge]? }
        struct Edge: Decodable { let node: Node? }
        struct Node: Decodable {
            let series: Series?
            let ratingsSummary: Summary?
        }
        struct Series: Decodable { let displayableEpisodeNumber: Displayable? }
        struct Displayable: Decodable { let episodeNumber: Text? }
        struct Text: Decodable { let text: String }
        struct Summary: Decodable { let aggregateRating: Double?; let voteCount: Int? }
        let data: DataBody?
    }
}
