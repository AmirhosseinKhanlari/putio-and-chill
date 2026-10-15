import AMDBCore
import Foundation

/// A notification for a new episode of a followed show.
public struct EpisodeAlert: Sendable, Equatable {
    public let id: String
    public let tmdbID: Int
    public let title: String
    public let body: String
    public let date: Date
}

/// Shows you follow for new episodes (bell in Coming Up and Settings). The app schedules a local notification on each
/// show's next release day; this decides what and when.
@Observable @MainActor
public final class EpisodeAlerts {
    public private(set) var followed: [SavedTitle] = []
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private var catalog: (any CatalogService)?

    public init(store: LocalStore) { self.store = store }

    public func configure(catalog: (any CatalogService)?) { self.catalog = catalog }

    public func load() async { followed = await store.snapshot.followedShows }

    public func isFollowing(_ tmdbID: Int) -> Bool { followed.contains { $0.tmdbID == tmdbID } }

    public func setFollowing(_ show: CatalogItem, _ on: Bool) async {
        followed.removeAll { $0.tmdbID == show.tmdbID }
        if on { followed.insert(SavedTitle(show), at: 0) }
        let list = followed
        await store.update { $0.followedShows = list }
    }

    /// The next episode of each followed show (TMDB), for scheduling.
    public func upcoming() async -> [UpcomingEpisode] {
        guard let catalog else { return [] }
        let ids = followed.map(\.tmdbID)
        return await withTaskGroup(of: UpcomingEpisode?.self) { group in
            for id in ids { group.addTask { try? await catalog.nextEpisode(tvID: id) } }
            var found: [UpcomingEpisode] = []
            for await episode in group { if let episode { found.append(episode) } }
            return found
        }
    }

    /// One notification per episode, on its air date at `hour` (local). Episodes whose alert time has passed are
    /// skipped; at most 60 (iOS keeps 64 pending notifications per app).
    public nonisolated static func alerts(for episodes: [UpcomingEpisode], hour: Int, now: Date,
                                          calendar: Calendar = .current) -> [EpisodeAlert] {
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let alerts: [EpisodeAlert] = episodes.compactMap { episode in
            guard let day = parser.date(from: episode.airDate),
                  let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), date > now else { return nil }
            let name = episode.name.isEmpty ? "" : " · \(episode.name)"
            return EpisodeAlert(id: "episode-\(episode.show.tmdbID)-\(episode.season)-\(episode.episode)",
                                tmdbID: episode.show.tmdbID, title: "New episode of \(episode.show.title)",
                                body: "S\(episode.season) E\(episode.episode)\(name) is out today.", date: date)
        }
        return Array(alerts.sorted { $0.date < $1.date }.prefix(60))
    }
}
