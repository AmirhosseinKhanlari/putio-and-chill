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
    /// Trakt's community average, 0–10 (from Trakt itself, so it shows without an MDBList key).
    public var trakt: Double?

    public init(imdb: Double? = nil, imdbVotes: Int? = nil, tomatoes: Int? = nil, popcorn: Int? = nil, metacritic: Int? = nil,
                letterboxd: Double? = nil, trakt: Double? = nil) {
        self.imdb = imdb; self.imdbVotes = imdbVotes; self.tomatoes = tomatoes; self.popcorn = popcorn; self.metacritic = metacritic
        self.letterboxd = letterboxd; self.trakt = trakt
    }

    public var isEmpty: Bool { imdb == nil && tomatoes == nil && popcorn == nil && metacritic == nil && letterboxd == nil && trakt == nil }

    /// These scores with any gaps filled from `other`.
    public func merged(with other: Ratings) -> Ratings {
        Ratings(imdb: imdb ?? other.imdb, imdbVotes: imdb != nil ? imdbVotes : other.imdbVotes, tomatoes: tomatoes ?? other.tomatoes,
                popcorn: popcorn ?? other.popcorn, metacritic: metacritic ?? other.metacritic,
                letterboxd: letterboxd ?? other.letterboxd, trakt: trakt ?? other.trakt)
    }
}

/// MDBList: `GET https://api.mdblist.com/{imdb|tmdb}/{movie|show}/{id}?apikey=…`.
public struct RatingsClient: Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let http: HTTPRequester

    public init(apiKey: String, transport: any HTTPTransport, baseURL: URL = URL(string: "https://api.mdblist.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = HTTPRequester(service: "mdblist", transport: transport)
    }

    /// Looks the title up by IMDb id, and by TMDB id when that finds nothing: many shows (and new titles) have no
    /// IMDb id on TMDB, or one MDBList hasn't rated yet. Empty when neither lookup has a score.
    public func ratings(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Ratings {
        let imdbID = imdbID?.trimmingCharacters(in: .whitespaces)
        if let imdbID, !imdbID.isEmpty {
            let found = try await lookup("imdb", imdbID, kind: kind)
            if !found.isEmpty { return found }
        }
        guard let tmdbID else { return Ratings() }
        return try await lookup("tmdb", String(tmdbID), kind: kind)
    }

    /// One MDBList lookup. A title MDBList doesn't know (404) has no scores rather than being an error.
    func lookup(_ provider: String, _ id: String, kind: MediaKind) async throws -> Ratings {
        let type = kind == .tv ? "show" : "movie"
        var components = URLComponents(url: baseURL.appending(path: "\(provider)/\(type)/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        do {
            return Self.parse(try await http.decode(Response.self, .get(components.url!)))
        } catch AppError.http(_, 404) {
            return Ratings()
        }
    }

    /// MDBList sends each source as `value` (the source's own scale) and `score` (0–100); either may be null.
    static func parse(_ response: Response) -> Ratings {
        var ratings = Ratings()
        for entry in response.ratings ?? [] {
            let value = entry.value?.value
            let score = entry.score?.value
            let percent = (value ?? score).map { Int($0.rounded()) }
            switch entry.source?.lowercased() {
            case "imdb":
                if let value, value > 0, value <= 10 {
                    ratings.imdb = value
                } else if let score, score > 0 {
                    ratings.imdb = score.rounded() / 10
                }
                if ratings.imdb != nil { ratings.imdbVotes = entry.votes?.value.map { Int($0) } }
            case "tomatoes", "rtomatoes", "rottentomatoes": ratings.tomatoes = percent ?? ratings.tomatoes
            case "popcorn", "tomatoesaudience", "audience", "rtaudience": ratings.popcorn = percent ?? ratings.popcorn
            case "metacritic": ratings.metacritic = percent ?? ratings.metacritic
            case "letterboxd":
                // Stars out of 5; fall back to MDBList's 0–100 score if the value is missing.
                if let value, value > 0, value <= 5 {
                    ratings.letterboxd = value
                } else if let score, score > 0 {
                    ratings.letterboxd = (score / 20 * 10).rounded() / 10
                }
            default: break
            }
        }
        return ratings
    }

    /// Cheap call used to check a key before saving it.
    public func validate() async throws {
        _ = try await lookup("imdb", "tt0816692", kind: .movie)
    }

    struct Response: Decodable { let ratings: [Entry]? }
    struct Entry: Decodable {
        let source: String?
        let value: LossyDouble?
        let score: LossyDouble?
        let votes: LossyDouble?
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
