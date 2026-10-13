import Foundation

public protocol SourceProvider: Sendable {
    var id: String { get }
    func releases(for query: MediaQuery) async throws -> [Release]
}

public enum ReleaseRelevance {
    /// Filters free-text search hits down to what the query actually asked for.
    public static func matches(_ p: ParsedRelease, _ query: MediaQuery) -> Bool {
        switch query {
        case let .episode(_, _, season, episode):
            guard p.season == season, let first = p.episode else { return false }
            return first == episode || (p.episodeEnd.map { episode >= first && episode <= $0 } ?? false)
        case let .season(_, _, season):
            return p.season == season && p.episode == nil
        case let .movie(_, _, year):
            guard p.season == nil else { return false }
            if let year, let found = p.year { return abs(found - year) <= 1 }
            return true
        case .text:
            return true
        }
    }
}
