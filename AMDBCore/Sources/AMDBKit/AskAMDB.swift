import AMDBCore
import Foundation

/// What a natural-language request ("a twisty 90s thriller under 2 hours") means as filters. Apple Intelligence fills
/// this in on iPhone and iPad; everything after that is plain TMDB.
public struct AskRequest: Sendable, Equatable {
    public enum Kind: String, Sendable { case movie, tv, any }
    public enum Sort: String, Sendable { case popular, rating, newest }

    public var kind: Kind
    /// TMDB genre names ("Thriller", "Science Fiction", "Sci-Fi & Fantasy", …).
    public var genres: [String]
    public var yearFrom: Int?
    public var yearTo: Int?
    public var maxRuntime: Int?
    public var minRating: Double?
    /// "something like Severance"
    public var similarTo: String?
    /// Mood or topic words ("heist", "time travel"), matched to TMDB keywords.
    public var keywords: [String]
    /// ISO 639-1 ("ko" for Korean films).
    public var language: String?
    public var sort: Sort

    public init(kind: Kind = .any, genres: [String] = [], yearFrom: Int? = nil, yearTo: Int? = nil, maxRuntime: Int? = nil,
                minRating: Double? = nil, similarTo: String? = nil, keywords: [String] = [], language: String? = nil,
                sort: Sort = .popular) {
        self.kind = kind; self.genres = genres; self.yearFrom = yearFrom; self.yearTo = yearTo; self.maxRuntime = maxRuntime
        self.minRating = minRating; self.similarTo = similarTo; self.keywords = keywords; self.language = language; self.sort = sort
    }

    /// Kinds to search: both for "any".
    public var kinds: [MediaKind] { kind == .tv ? [.tv] : kind == .movie ? [.movie] : [.movie, .tv] }

    /// "Thriller · 1990–1999 · under 2 h · 7+" — shown above the results so you can see how it was understood.
    public var summary: String {
        var parts: [String] = []
        if kind != .any { parts.append(kind == .tv ? "Series" : "Movies") }
        parts += genres
        switch (yearFrom, yearTo) {
        case let (from?, to?): parts.append(from == to ? "\(from)" : "\(from)–\(to)")
        case let (from?, nil): parts.append("since \(from)")
        case let (nil, to?): parts.append("before \(to + 1)")
        default: break
        }
        if let maxRuntime { parts.append(maxRuntime % 60 == 0 ? "under \(maxRuntime / 60) h" : "under \(maxRuntime) min") }
        if let minRating { parts.append(String(format: "%g+", minRating)) }
        if let language { parts.append(Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language) }
        parts += keywords.map { "\u{201C}\($0)\u{201D}" }
        if let similarTo { parts.append("like \(similarTo)") }
        return parts.joined(separator: " · ")
    }

    /// TMDB /discover filters for one kind; keyword ids come from TMDB's keyword search.
    public func query(for kind: MediaKind, keywordIDs: [Int] = []) -> DiscoverQuery {
        let tv = kind == .tv
        var p: [String: String] = [
            "sort_by": sort == .rating ? "vote_average.desc" : sort == .newest ? (tv ? "first_air_date.desc" : "primary_release_date.desc") : "popularity.desc",
            "vote_count.gte": sort == .rating ? "300" : "50",
        ]
        let ids = genres.compactMap { Self.genreID($0, kind: kind) }
        if !ids.isEmpty { p["with_genres"] = ids.map(String.init).joined(separator: ",") }
        let dateKey = tv ? "first_air_date" : "primary_release_date"
        if let yearFrom { p["\(dateKey).gte"] = "\(yearFrom)-01-01" }
        if let yearTo { p["\(dateKey).lte"] = "\(yearTo)-12-31" }
        if let maxRuntime { p["with_runtime.lte"] = String(maxRuntime) }
        if let minRating { p["vote_average.gte"] = String(format: "%.1f", minRating) }
        if let language { p["with_original_language"] = language }
        if !keywordIDs.isEmpty { p["with_keywords"] = keywordIDs.map(String.init).joined(separator: "|") }
        return DiscoverQuery(p)
    }

    /// TMDB genre id for a name, per kind (movie and TV genre lists differ; a few names map across).
    public static func genreID(_ name: String, kind: MediaKind) -> Int? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let table = kind == .tv ? tvGenres : movieGenres
        if let id = table[key] { return id }
        // Movie words for TV and back.
        let aliases: [String: String] = kind == .tv
            ? ["science fiction": "sci-fi & fantasy", "fantasy": "sci-fi & fantasy", "sci-fi": "sci-fi & fantasy",
               "action": "action & adventure", "adventure": "action & adventure", "thriller": "mystery", "war": "war & politics",
               "horror": "mystery"]
            : ["sci-fi": "science fiction", "sci-fi & fantasy": "science fiction", "action & adventure": "action",
               "war & politics": "war", "kids": "family", "scary": "horror", "romcom": "romance"]
        return aliases[key].flatMap { table[$0] }
    }

    public static let genreNames = ["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama", "Family",
                                    "Fantasy", "History", "Horror", "Music", "Mystery", "Romance", "Science Fiction",
                                    "Thriller", "War", "Western"]

    static let movieGenres: [String: Int] = [
        "action": 28, "adventure": 12, "animation": 16, "comedy": 35, "crime": 80, "documentary": 99, "drama": 18,
        "family": 10751, "fantasy": 14, "history": 36, "horror": 27, "music": 10402, "mystery": 9648, "romance": 10749,
        "science fiction": 878, "thriller": 53, "war": 10752, "western": 37,
    ]
    static let tvGenres: [String: Int] = [
        "action & adventure": 10759, "animation": 16, "comedy": 35, "crime": 80, "documentary": 99, "drama": 18,
        "family": 10751, "kids": 10762, "mystery": 9648, "reality": 10764, "sci-fi & fantasy": 10765, "war & politics": 10768,
        "western": 37, "romance": 10749,
    ]
}

/// Runs an AskRequest against TMDB: "like X" uses X's recommendations; otherwise discover with the filters.
public enum AskSearch {
    public static func run(_ request: AskRequest, catalog: any CatalogService) async -> [CatalogItem] {
        if let similar = request.similarTo, !similar.isEmpty,
           let source = try? await catalog.searchMulti(similar).first(where: { $0.mediaType != .person }),
           let detail = try? await catalog.detail(source.mediaType, id: source.tmdbID), !detail.recommendations.isEmpty {
            return detail.recommendations.filter { item in
                (request.kind == .any || item.mediaType.rawValue == request.kind.rawValue)
                    && (request.yearFrom.map { from in (item.year ?? from) >= from } ?? true)
                    && (request.yearTo.map { to in (item.year ?? to) <= to } ?? true)
                    && (request.minRating.map { min in (item.voteAverage ?? min) >= min } ?? true)
            }
        }
        var keywordIDs: [Int] = []
        for word in request.keywords.prefix(3) {
            if let id = try? await catalog.keywordIDs(word).first { keywordIDs.append(id) }
        }
        var results: [CatalogItem] = []
        for kind in request.kinds {
            let found = (try? await catalog.discover(kind, query: request.query(for: kind, keywordIDs: keywordIDs))) ?? []
            // Keywords can be too narrow; fall back to the other filters.
            if found.isEmpty, !keywordIDs.isEmpty {
                results += (try? await catalog.discover(kind, query: request.query(for: kind))) ?? []
            } else {
                results += found
            }
        }
        // Mix movies and shows by popularity order: alternate.
        guard request.kinds.count > 1 else { return results }
        let movies = results.filter { $0.mediaType == .movie }, shows = results.filter { $0.mediaType == .tv }
        return (0..<max(movies.count, shows.count)).flatMap { i in [movies[safe: i], shows[safe: i]].compactMap { $0 } }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
