import Foundation

public protocol CatalogSearching: Sendable {
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem]
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem]
    /// How many seasons a show has (TMDB's `number_of_seasons`); nil when unknown.
    func seasonCount(tvID: Int) async throws -> Int?
}

extension CatalogSearching {
    public func seasonCount(tvID: Int) async throws -> Int? { nil }
}

extension CatalogClient: CatalogSearching {}

public struct LibraryMatch: Sendable, Equatable, Hashable, Codable {
    public let tmdbID: Int
    public let mediaType: MediaKind
    public let season: Int?
    public let episode: Int?
    public let confidence: Double
    public let title: String
    public let year: Int?
    public let posterPath: String?
    public let backdropPath: String?

    public init(tmdbID: Int, mediaType: MediaKind, season: Int?, episode: Int?, confidence: Double,
                title: String = "", year: Int? = nil, posterPath: String? = nil, backdropPath: String? = nil) {
        self.tmdbID = tmdbID; self.mediaType = mediaType; self.season = season; self.episode = episode
        self.confidence = confidence; self.title = title; self.year = year
        self.posterPath = posterPath; self.backdropPath = backdropPath
    }
}

public struct LibraryMatcher: Sendable {
    private let catalog: any CatalogSearching
    /// Season counts already looked up: every episode file of a show asks about the same show.
    private let seasonCounts = SeasonCounts()

    public init(catalog: any CatalogSearching) { self.catalog = catalog }

    public func match(fileName: String) async throws -> LibraryMatch? {
        let parsed = ReleaseNameParser.parse(fileName)
        guard !parsed.title.isEmpty else { return nil }
        let isTV = parsed.season != nil
        let best: (item: CatalogItem, confidence: Double)?
        if isTV {
            // Searched without the year (a show's first-air year rarely matches the year in an episode's name), then
            // picked with it: "Monster.2022.S03E01" is not the 2004 "Monster".
            let results = try await catalog.searchTV(title: parsed.title, year: nil)
            best = try await pickShow(results, title: parsed.title, year: parsed.year, season: parsed.season ?? 1)
        } else {
            let results = try await catalog.searchMovie(title: parsed.title, year: parsed.year)
            best = Self.pick(results, title: parsed.title, year: parsed.year)
        }
        guard let best else { return nil }
        return LibraryMatch(tmdbID: best.item.tmdbID, mediaType: isTV ? .tv : .movie,
                            season: parsed.season, episode: parsed.episode, confidence: best.confidence,
                            title: best.item.title, year: best.item.year,
                            posterPath: best.item.posterPath, backdropPath: best.item.backdropPath)
    }

    /// The show a file belongs to. With a year in the name: same title from that year (±1) first, then the one longer
    /// title starting with it from exactly that year ("Monster" 2025 → "Monster: The Ed Gein Story"). A same-title show from another
    /// year (or a name without a year) only counts when it has the file's season: TMDB's anime "Monster" (2004, one
    /// season) isn't the home of "Monster S03". When nothing fits the file stays unmatched (Fix Match can set it).
    func pickShow(_ items: [CatalogItem], title: String, year: Int?, season: Int) async throws -> (item: CatalogItem, confidence: Double)? {
        let wanted = Self.normalize(title)
        let exact = items.filter { Self.normalize($0.title) == wanted }
        if let year {
            if let fits = exact.first(where: { Self.yearFits($0, year) }) { return (fits, 1.0) }
            // Only from that exact year, and only when one title fits: an anthology has a "Monster: …" every year.
            let longer = items.filter { item in
                item.year == year && item.title.contains(":")
                    && ReleaseRelevance.words(item.title).starts(with: ReleaseRelevance.words(title))
            }
            if longer.count == 1 { return (longer[0], 0.6) }
        }
        for candidate in exact {
            if season > 1, let count = await seasonCounts.count(candidate.tmdbID, catalog), count < season { continue }
            return (candidate, year == nil ? 1.0 : 0.6)
        }
        return nil
    }

    static func yearFits(_ item: CatalogItem, _ year: Int) -> Bool {
        item.year.map { abs($0 - year) <= 1 } ?? false
    }

    public static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
    }

    public static func pick(_ items: [CatalogItem], title: String, year: Int?) -> (item: CatalogItem, confidence: Double)? {
        let wanted = normalize(title)
        func yearOK(_ item: CatalogItem) -> Bool {
            guard let year else { return true }
            guard let found = item.year else { return false }
            return abs(found - year) <= 1
        }
        if let exact = items.first(where: { normalize($0.title) == wanted && yearOK($0) }) { return (exact, 1.0) }
        if let titleOnly = items.first(where: { normalize($0.title) == wanted }) { return (titleOnly, 0.7) }
        if year != nil, let first = items.first, yearOK(first) { return (first, 0.5) }
        return nil
    }
}

/// Show id → number of seasons, looked up once per show (a failed lookup is retried next time).
actor SeasonCounts {
    private var known: [Int: Int] = [:]

    func count(_ tvID: Int, _ catalog: any CatalogSearching) async -> Int? {
        if let count = known[tvID] { return count }
        guard let count = try? await catalog.seasonCount(tvID: tvID) else { return nil }
        known[tvID] = count
        return count
    }
}
