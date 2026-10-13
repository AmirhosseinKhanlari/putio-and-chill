import Foundation

/// Critic and audience scores for one title. Nil means the source has no score for it.
public struct Ratings: Sendable, Hashable, Codable {
    public var imdb: Double?
    public var imdbVotes: Int?
    /// Rotten Tomatoes critics (Tomatometer), 0–100.
    public var tomatoes: Int?
    /// Rotten Tomatoes audience (Popcornmeter), 0–100.
    public var popcorn: Int?
    public var metacritic: Int?
    /// Letterboxd average, 0–5 stars.
    public var letterboxd: Double?

    public init(imdb: Double? = nil, imdbVotes: Int? = nil, tomatoes: Int? = nil, popcorn: Int? = nil, metacritic: Int? = nil,
                letterboxd: Double? = nil) {
        self.imdb = imdb; self.imdbVotes = imdbVotes; self.tomatoes = tomatoes; self.popcorn = popcorn; self.metacritic = metacritic
        self.letterboxd = letterboxd
    }

    public var isEmpty: Bool { imdb == nil && tomatoes == nil && popcorn == nil && metacritic == nil && letterboxd == nil }
}

/// MDBList: `GET https://api.mdblist.com/imdb/{movie|show}/{imdbID}?apikey=…`.
public struct RatingsClient: Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(apiKey: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.mdblist.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "mdblist", transport: transport)
    }

    public func ratings(imdbID: String, kind: MediaKind) async throws -> Ratings {
        let type = kind == .tv ? "show" : "movie"
        var components = URLComponents(url: baseURL.appending(path: "imdb/\(type)/\(imdbID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        let response = try await http.decode(Response.self, .get(components.url!))
        var ratings = Ratings()
        for entry in response.ratings ?? [] {
            let percent = entry.value?.value.map { Int($0.rounded()) } ?? entry.score?.value.map(Int.init)
            switch entry.source.lowercased() {
            case "imdb":
                ratings.imdb = entry.value?.value
                ratings.imdbVotes = entry.votes?.value.map(Int.init)
            case "tomatoes": ratings.tomatoes = percent
            case "popcorn", "tomatoesaudience": ratings.popcorn = percent
            case "metacritic": ratings.metacritic = percent
            case "letterboxd":
                // Stars out of 5; fall back to MDBList's 0–100 score if the value is missing.
                if let stars = entry.value?.value, stars > 0, stars <= 5 {
                    ratings.letterboxd = stars
                } else if let score = entry.score?.value, score > 0 {
                    ratings.letterboxd = (Double(score) / 20 * 10).rounded() / 10
                }
            default: break
            }
        }
        return ratings
    }

    /// Cheap call used to check a key before saving it.
    public func validate() async throws {
        _ = try await ratings(imdbID: "tt0816692", kind: .movie)
    }

    struct Response: Decodable { let ratings: [Entry]? }
    struct Entry: Decodable {
        let source: String
        let value: LossyDouble?
        let score: LossyInt64?
        let votes: LossyInt64?
    }
}

/// Decodes a number sent as a JSON number or numeric string.
public struct LossyDouble: Decodable, Sendable, Hashable {
    public let value: Double?
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}
