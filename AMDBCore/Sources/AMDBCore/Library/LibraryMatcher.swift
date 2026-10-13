import Foundation

public protocol CatalogSearching: Sendable {
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem]
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem]
}

extension CatalogClient: CatalogSearching {}

public struct LibraryMatch: Sendable, Equatable, Hashable {
    public let tmdbID: Int
    public let mediaType: MediaKind
    public let season: Int?
    public let episode: Int?
    public let confidence: Double

    public init(tmdbID: Int, mediaType: MediaKind, season: Int?, episode: Int?, confidence: Double) {
        self.tmdbID = tmdbID; self.mediaType = mediaType; self.season = season; self.episode = episode; self.confidence = confidence
    }
}

public struct LibraryMatcher: Sendable {
    private let catalog: any CatalogSearching

    public init(catalog: any CatalogSearching) { self.catalog = catalog }

    public func match(fileName: String) async throws -> LibraryMatch? {
        let parsed = ReleaseNameParser.parse(fileName)
        guard !parsed.title.isEmpty else { return nil }
        let isTV = parsed.season != nil
        let results = isTV
            ? try await catalog.searchTV(title: parsed.title, year: nil)
            : try await catalog.searchMovie(title: parsed.title, year: parsed.year)
        guard let best = Self.pick(results, title: parsed.title, year: isTV ? nil : parsed.year) else { return nil }
        return LibraryMatch(tmdbID: best.item.tmdbID, mediaType: isTV ? .tv : .movie,
                            season: parsed.season, episode: parsed.episode, confidence: best.confidence)
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
