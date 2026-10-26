import AMDBCore
import Foundation

/// One episode of a show, as the key of what comes after it.
public struct EpisodeKey: Hashable, Sendable {
    public let tmdbID: Int
    public let season: Int
    public let episode: Int

    public init(tmdbID: Int, season: Int, episode: Int) {
        self.tmdbID = tmdbID; self.season = season; self.episode = episode
    }
}

/// What TMDB said comes after a watched episode (nil: it was the last one aired), and when it was asked: it's asked
/// again later, as a new episode may have aired since.
struct UpNextFound: Sendable, Equatable {
    struct Next: Sendable, Equatable { let season: Int; let episode: Int; let name: String? }
    let next: Next?
    let at: Date
}

/// The episode after the one just watched, in Continue Watching.
public struct UpNextCard: Sendable, Hashable, Identifiable {
    public let tmdbID: Int
    public let showTitle: String
    public let posterPath: String?
    public let backdropPath: String?
    public let year: Int?
    public let season: Int
    public let episode: Int
    /// The episode's name, once TMDB has told it.
    public let name: String?
    /// The file in put.io; nil when it isn't there (its card opens the show's page instead).
    public let entry: LibraryEntry?
    /// The watched episode before it.
    public let after: Int64

    public var id: String { "upnext-\(tmdbID)" }
    public var isInPutio: Bool { entry != nil }
    public var episodeLabel: String { "S\(season) E\(episode)" }
    /// "Up Next · S2 E5", and "· Not in put.io" when it isn't there.
    public var label: String { "Up Next · \(episodeLabel)" + (isInPutio ? "" : " · Not in put.io") }
    public var titleItem: CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: .tv, title: showTitle, posterPath: posterPath, backdropPath: backdropPath,
                    year: year)
    }
}

/// A card in Continue Watching: a video to resume, or a show's next episode after a watched one.
public enum WatchingCard: Sendable, Hashable, Identifiable {
    case resume(LibraryEntry)
    case upNext(UpNextCard)

    public var id: String {
        switch self {
        case let .resume(entry): "resume-\(entry.id)"
        case let .upNext(card): card.id
        }
    }

    public var resumeEntry: LibraryEntry? { if case let .resume(entry) = self { entry } else { nil } }
    public var upNext: UpNextCard? { if case let .upNext(card) = self { card } else { nil } }
    public var tmdbID: Int? {
        switch self {
        case let .resume(entry): entry.match?.tmdbID
        case let .upNext(card): card.tmdbID
        }
    }
}

extension LibraryIndex {
    /// How long TMDB's answer about a show's next episode is kept before it's asked again.
    public static let upNextMaxAge: TimeInterval = 12 * 3600

    /// Continue Watching, most recently watched first, one card per title, by what was watched last on it:
    /// - started (at least 30 seconds, not watched): resume it;
    /// - a watched movie: gone;
    /// - a watched episode: the show's next episode, up next (once known to have aired: TMDB, else the next file in
    ///   put.io). None when it was the last one aired, until TMDB lists a newer one.
    public var continueWatchingCards: [WatchingCard] {
        latestPerTitle.compactMap { entry in
            isWatched(entry) ? upNextCard(after: entry).map(WatchingCard.upNext) : .resume(entry)
        }
    }

    /// The card for one show or movie, if it's in Continue Watching (its page's main button follows it).
    public func watchingCard(tmdbID: Int) -> WatchingCard? {
        continueWatchingCards.first { $0.tmdbID == tmdbID }
    }

    /// Watched episodes whose next one TMDB hasn't been asked about lately (`AppModel.findUpNext`).
    public func upNextToFind(now: Date = Date()) -> [EpisodeKey] {
        latestPerTitle.filter(isWatched).compactMap(Self.episodeKey).filter { key in
            guard let found = upNextFound[key] else { return true }
            return now.timeIntervalSince(found.at) >= Self.upNextMaxAge
        }
    }

    /// What TMDB said comes after `key`. Not knowing (TMDB unreachable) changes nothing: the next file in put.io stands in.
    public func noteUpNext(_ lookup: NextUpLookup, after key: EpisodeKey, now: Date = Date()) {
        switch lookup {
        case let .next(next):
            upNextFound[key] = UpNextFound(next: .init(season: next.season, episode: next.episode, name: next.name), at: now)
        case .none:
            upNextFound[key] = UpNextFound(next: nil, at: now)
        case .unknown:
            break
        }
    }

    /// Started or watched files, the most recently watched one of each title. Watched specials (season 0) don't
    /// count: a show's place in its seasons decides what's up next.
    private var latestPerTitle: [LibraryEntry] {
        let active = entries.filter { entry in
            resumeSeconds(for: entry) >= 30 || (isWatched(entry) && entry.match?.season != 0)
        }.sorted(by: watchedLater)
        var seen: Set<String> = []
        return active.filter { entry in
            seen.insert(entry.match.map { "\($0.mediaType.rawValue)-\($0.tmdbID)" } ?? "file-\(entry.id)").inserted
        }
    }

    private static func episodeKey(_ entry: LibraryEntry) -> EpisodeKey? {
        guard let match = entry.match, match.mediaType == .tv, let season = match.season, season > 0,
              let episode = match.episode else { return nil }
        return EpisodeKey(tmdbID: match.tmdbID, season: season, episode: episode)
    }

    private func upNextCard(after watched: LibraryEntry) -> UpNextCard? {
        guard let key = Self.episodeKey(watched), let show = watched.match else { return nil }
        let next: UpNextFound.Next
        if let found = upNextFound[key] {
            guard let known = found.next else { return nil }
            next = known
        } else if let file = NextUpFinder.inLibrary(tmdbID: key.tmdbID, season: key.season, episode: key.episode, library: self) {
            next = .init(season: file.season, episode: file.episode, name: nil)
        } else {
            return nil
        }
        let entry = NextUpFinder.best(matching(tmdbID: key.tmdbID, season: next.season, episode: next.episode), self)
        return UpNextCard(tmdbID: key.tmdbID, showTitle: show.title, posterPath: show.posterPath ?? entry?.match?.posterPath,
                          backdropPath: show.backdropPath ?? entry?.match?.backdropPath, year: show.year,
                          season: next.season, episode: next.episode, name: next.name, entry: entry, after: watched.id)
    }
}
