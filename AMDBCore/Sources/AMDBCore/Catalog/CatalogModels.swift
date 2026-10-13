import Foundation

public enum MediaKind: String, Sendable, Codable, Hashable { case movie, tv, person }

public struct CatalogItem: Sendable, Hashable, Identifiable, Decodable {
    public let tmdbID: Int
    public let mediaType: MediaKind
    public let title: String
    public let overview: String
    public let posterPath: String?
    public let backdropPath: String?
    public let profilePath: String?
    public let year: Int?
    public let voteAverage: Double?
    public let genreIDs: [Int]
    public let knownFor: [CatalogItem]

    public var id: String { "\(mediaType.rawValue)-\(tmdbID)" }

    // Keys are camelCase because decoding uses .convertFromSnakeCase.
    enum CodingKeys: String, CodingKey {
        case id, mediaType, title, name, overview, posterPath, backdropPath, profilePath
        case releaseDate, firstAirDate, voteAverage, genreIds, knownFor
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = try c.decode(Int.self, forKey: .id)
        let movieTitle = try c.decodeIfPresent(String.self, forKey: .title)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        mediaType = try c.decodeIfPresent(MediaKind.self, forKey: .mediaType) ?? (movieTitle != nil ? .movie : .tv)
        title = movieTitle ?? name ?? ""
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try c.decodeIfPresent(String.self, forKey: .backdropPath)
        profilePath = try c.decodeIfPresent(String.self, forKey: .profilePath)
        let date = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? c.decodeIfPresent(String.self, forKey: .firstAirDate)
        year = date.flatMap { Int($0.prefix(4)) }
        voteAverage = try c.decodeIfPresent(Double.self, forKey: .voteAverage)
        genreIDs = try c.decodeIfPresent([Int].self, forKey: .genreIds) ?? []
        knownFor = try c.decodeIfPresent([CatalogItem].self, forKey: .knownFor) ?? []
    }
}

public struct CastMember: Sendable, Hashable { public let name: String; public let character: String?; public let profilePath: String? }
public struct SeasonSummary: Sendable, Hashable { public let number: Int; public let name: String; public let episodeCount: Int; public let posterPath: String? }
public struct Episode: Sendable, Hashable, Identifiable {
    public let number: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    public let runtimeMinutes: Int?
    public let airDate: String?
    public var id: Int { number }
}

public struct TitleDetail: Sendable, Equatable {
    public let item: CatalogItem
    public let imdbID: String?
    public let runtimeMinutes: Int?
    public let genres: [String]
    public let cast: [CastMember]
    public let trailerYouTubeKey: String?
    public let logoPath: String?
    public let recommendations: [CatalogItem]
    public let seasons: [SeasonSummary]
}

struct DetailRaw: Decodable {
    struct Named: Decodable { let name: String }
    struct Credits: Decodable { let cast: [Cast]? }
    struct Cast: Decodable { let name: String; let character: String?; let profilePath: String? }
    struct Videos: Decodable { let results: [Video]? }
    struct Video: Decodable { let key: String; let site: String?; let type: String? }
    struct Images: Decodable { let logos: [Logo]? }
    struct Logo: Decodable { let filePath: String; let iso6391: String? }
    struct External: Decodable { let imdbId: String? }
    struct Page: Decodable { let results: [CatalogItem]? }
    struct Season: Decodable { let seasonNumber: Int; let name: String?; let episodeCount: Int?; let posterPath: String? }

    let runtime: Int?
    let episodeRunTime: [Int]?
    let imdbId: String?
    let externalIds: External?
    let genres: [Named]?
    let credits: Credits?
    let videos: Videos?
    let images: Images?
    let recommendations: Page?
    let seasons: [Season]?
}

struct SeasonRaw: Decodable {
    struct Ep: Decodable {
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let runtime: Int?
        let airDate: String?
    }
    let episodes: [Ep]?
}
