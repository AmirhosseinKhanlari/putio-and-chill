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

    public init(tmdbID: Int, mediaType: MediaKind, title: String, overview: String = "", posterPath: String? = nil,
                backdropPath: String? = nil, profilePath: String? = nil, year: Int? = nil, voteAverage: Double? = nil,
                genreIDs: [Int] = [], knownFor: [CatalogItem] = []) {
        self.tmdbID = tmdbID; self.mediaType = mediaType; self.title = title; self.overview = overview
        self.posterPath = posterPath; self.backdropPath = backdropPath; self.profilePath = profilePath
        self.year = year; self.voteAverage = voteAverage; self.genreIDs = genreIDs; self.knownFor = knownFor
    }

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

public struct CastMember: Sendable, Hashable {
    public let name: String
    public let character: String?
    public let profilePath: String?

    public init(name: String, character: String?, profilePath: String?) {
        self.name = name; self.character = character; self.profilePath = profilePath
    }
}

public struct SeasonSummary: Sendable, Hashable {
    public let number: Int
    public let name: String
    public let episodeCount: Int
    public let posterPath: String?

    public init(number: Int, name: String, episodeCount: Int, posterPath: String?) {
        self.number = number; self.name = name; self.episodeCount = episodeCount; self.posterPath = posterPath
    }
}
public struct Episode: Sendable, Hashable, Identifiable {
    public let number: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    public let runtimeMinutes: Int?
    public let airDate: String?
    public var id: Int { number }

    public init(number: Int, name: String, overview: String = "", stillPath: String? = nil,
                runtimeMinutes: Int? = nil, airDate: String? = nil) {
        self.number = number; self.name = name; self.overview = overview; self.stillPath = stillPath
        self.runtimeMinutes = runtimeMinutes; self.airDate = airDate
    }
}

public struct TitleDetail: Sendable, Equatable {
    public let item: CatalogItem
    public let imdbID: String?
    public let runtimeMinutes: Int?
    public let genres: [String]
    public let cast: [CastMember]
    /// Key crew (creators, directors, writers, composer); `character` holds the job, e.g. "Director, Screenplay".
    public let crew: [CastMember]
    public let trailerYouTubeKey: String?
    public let logoPath: String?
    public let recommendations: [CatalogItem]
    public let seasons: [SeasonSummary]

    public init(item: CatalogItem, imdbID: String?, runtimeMinutes: Int? = nil, genres: [String] = [],
                cast: [CastMember] = [], crew: [CastMember] = [], trailerYouTubeKey: String? = nil, logoPath: String? = nil,
                recommendations: [CatalogItem] = [], seasons: [SeasonSummary] = []) {
        self.item = item; self.imdbID = imdbID; self.runtimeMinutes = runtimeMinutes; self.genres = genres
        self.cast = cast; self.crew = crew; self.trailerYouTubeKey = trailerYouTubeKey; self.logoPath = logoPath
        self.recommendations = recommendations; self.seasons = seasons
    }
}

struct DetailRaw: Decodable {
    struct Named: Decodable { let name: String }
    struct Credits: Decodable { let cast: [Cast]?; let crew: [Crew]? }
    struct Crew: Decodable { let name: String; let job: String?; let profilePath: String? }
    struct Creator: Decodable { let name: String; let profilePath: String? }
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
    let createdBy: [Creator]?

    /// Creators first, then directors, writers and composer; one entry per person with their jobs joined.
    var keyCrew: [CastMember] {
        let priority = ["Director": 1, "Screenplay": 2, "Writer": 2, "Teleplay": 2, "Story": 3, "Novel": 3,
                        "Original Music Composer": 4]
        let display = ["Original Music Composer": "Composer"]
        var people: [(name: String, profile: String?, rank: Int, jobs: [String])] =
            (createdBy ?? []).map { ($0.name, $0.profilePath, 0, ["Creator"]) }
        for member in credits?.crew ?? [] {
            guard let job = member.job, let rank = priority[job] else { continue }
            let label = display[job] ?? job
            if let index = people.firstIndex(where: { $0.name == member.name }) {
                if !people[index].jobs.contains(label) { people[index].jobs.append(label) }
                people[index].rank = min(people[index].rank, rank)
                if people[index].profile == nil { people[index].profile = member.profilePath }
            } else {
                people.append((member.name, member.profilePath, rank, [label]))
            }
        }
        return people.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .prefix(12)
            .map { CastMember(name: $0.element.name, character: $0.element.jobs.joined(separator: ", "), profilePath: $0.element.profile) }
    }
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

/// One page of TMDB results.
public struct CatalogPage: Sendable, Equatable {
    public let items: [CatalogItem]
    public let page: Int
    public let totalPages: Int

    public init(items: [CatalogItem], page: Int, totalPages: Int) {
        self.items = items; self.page = page; self.totalPages = totalPages
    }

    public var hasMore: Bool { page < totalPages }
}
