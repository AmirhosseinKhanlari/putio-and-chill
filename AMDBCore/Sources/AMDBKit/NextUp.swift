import AMDBCore
import Foundation

/// The episode after the one playing (Netflix's "Next Episode"): what it is, whether it's already in put.io, and how
/// to get it if not. Found from TMDB wherever playback started (episode list, Continue Watching, Library, widgets).
public struct NextUp: Sendable, Equatable {
    public let showTitle: String
    public let season: Int
    public let episode: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    /// The file in put.io, when it's there (several versions: the one watched furthest, else the first).
    public let entry: LibraryEntry?
    /// For "Get Next Episode" when it isn't in put.io.
    public let query: MediaQuery?
    public let target: TransferTarget

    public var label: String { "S\(season) E\(episode)" }
    public var isInPutio: Bool { entry != nil }

    /// Seconds before the end at which the credits are assumed to start: 2.5% of the running time, 20–60 s
    /// (about 33 s for a half-hour show, a minute for an hour-long one).
    public static func creditsLength(duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(60, max(20, duration * 0.025))
    }

    /// How long the Next Episode button counts down before playing by itself.
    public static let countdown: Double = 8

    /// The same episode, looked up in put.io again: the library may have loaded, or the episode arrived, since it was found.
    @MainActor
    public func resolved(in library: LibraryIndex) -> NextUp {
        guard entry == nil else { return self }
        guard let found = NextUpFinder.best(library.matching(tmdbID: target.tmdbID, season: season, episode: episode), library)
        else { return self }
        return NextUp(showTitle: showTitle, season: season, episode: episode, name: name, overview: overview,
                      stillPath: stillPath, entry: found, query: query, target: target)
    }
}

/// What TMDB says comes after an episode.
public enum NextUpLookup: Sendable, Equatable {
    case next(NextUp)
    /// It's the last episode that has aired (so far).
    case none
    /// TMDB couldn't be reached: nothing is known.
    case unknown
}

public enum NextUpFinder {
    /// The next episode: the following one this season, else episode 1 of the next season (specials skipped).
    /// Only episodes that have aired. Falls back to put.io alone when TMDB can't be reached.
    @MainActor
    public static func find(tmdbID: Int, season: Int, episode: Int, catalog: (any CatalogService)?,
                            library: LibraryIndex, today: Date = Date()) async -> NextUp? {
        switch await lookup(tmdbID: tmdbID, season: season, episode: episode, catalog: catalog, library: library, today: today) {
        case let .next(next): return next
        case .none: return nil
        case .unknown: return inLibrary(tmdbID: tmdbID, season: season, episode: episode, library: library)
        }
    }

    /// The next aired episode from TMDB alone, telling "there's none (yet)" apart from "TMDB didn't answer".
    @MainActor
    public static func lookup(tmdbID: Int, season: Int, episode: Int, catalog: (any CatalogService)?,
                              library: LibraryIndex, today: Date = Date()) async -> NextUpLookup {
        guard let catalog, let detail = try? await catalog.detail(.tv, id: tmdbID),
              let current = try? await catalog.season(tvID: tmdbID, number: season) else { return .unknown }
        var candidates = current.map { (season, $0) }
        if pick(after: (season, episode), from: candidates, today: today) == nil,
           let following = detail.seasons.map(\.number).filter({ $0 > season && $0 > 0 }).min() {
            guard let next = try? await catalog.season(tvID: tmdbID, number: following) else { return .unknown }
            candidates += next.map { (following, $0) }
        }
        guard let (s, e) = pick(after: (season, episode), from: candidates, today: today) else { return .none }
        return .next(make(tmdbID: tmdbID, detail: detail, season: s, episode: e, library: library))
    }

    /// TMDB unreachable: the next file in put.io, if any.
    @MainActor
    static func inLibrary(tmdbID: Int, season: Int, episode: Int, library: LibraryIndex) -> NextUp? {
        for (s, e) in [(season, episode + 1), (season + 1, 1)] {
            if let entry = best(library.matching(tmdbID: tmdbID, season: s, episode: e), library) {
                let title = entry.match?.title ?? entry.displayTitle
                return NextUp(showTitle: title, season: s, episode: e, name: "Episode \(e)", overview: "", stillPath: nil,
                              entry: entry, query: nil,
                              target: TransferTarget(tmdbID: tmdbID, kind: .tv, title: title, posterPath: entry.match?.posterPath,
                                                     backdropPath: entry.match?.backdropPath, season: s, episode: e))
            }
        }
        return nil
    }

    /// The first aired episode after `current`, in season/episode order.
    static func pick(after current: (season: Int, episode: Int), from candidates: [(Int, Episode)],
                     today: Date) -> (Int, Episode)? {
        let day = CuratedList.day(today, plus: 0)
        return candidates
            .filter { s, e in (s, e.number) > (current.season, current.episode) && s > 0 }
            .filter { _, e in e.airDate.map { !$0.isEmpty && $0 <= day } ?? false }
            .min { a, b in (a.0, a.1.number) < (b.0, b.1.number) }
    }

    @MainActor
    private static func make(tmdbID: Int, detail: TitleDetail, season: Int, episode: Episode, library: LibraryIndex) -> NextUp {
        let item = detail.item
        // Shows without an IMDb id are searched by title.
        let query = MediaQuery.episode(imdbID: detail.imdbID, title: item.title, season: season, episode: episode.number)
        return NextUp(showTitle: item.title, season: season, episode: episode.number, name: episode.name,
                      overview: episode.overview, stillPath: episode.stillPath ?? item.backdropPath,
                      entry: best(library.matching(tmdbID: tmdbID, season: season, episode: episode.number), library),
                      query: query,
                      target: TransferTarget(tmdbID: tmdbID, kind: .tv, title: item.title, posterPath: item.posterPath,
                                             backdropPath: item.backdropPath, season: season, episode: episode.number))
    }

    @MainActor
    static func best(_ entries: [LibraryEntry], _ library: LibraryIndex) -> LibraryEntry? {
        entries.max { library.resumeSeconds(for: $0) < library.resumeSeconds(for: $1) } ?? entries.first
    }
}
