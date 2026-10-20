import AMDBCore
import Foundation
import Observation

public enum TitleAction: Equatable, Sendable {
    case get
    case play(LibraryEntry)
    case resume(LibraryEntry, seconds: Int)
    case downloading(TrackedTransfer)
    case failed(TrackedTransfer)
}

@Observable @MainActor
public final class TitleModel {
    public let item: CatalogItem
    public private(set) var detail: TitleDetail?
    public private(set) var episodes: [Episode] = []
    public private(set) var selectedSeason: Int?
    public private(set) var error: AppError?
    public private(set) var ratings: Ratings?
    /// IMDb score per episode number for the selected season.
    public private(set) var episodeRatings: [Int: EpisodeRating] = [:]

    private let catalog: any CatalogService
    private let library: LibraryIndex
    private let transfers: TransferMonitor
    private let ratingsProvider: (@MainActor (String, MediaKind) async -> Ratings?)?
    private let episodeRatingsProvider: (@MainActor (String, Int) async -> [Int: EpisodeRating])?

    public init(item: CatalogItem, catalog: any CatalogService, library: LibraryIndex, transfers: TransferMonitor,
                ratings: (@MainActor (String, MediaKind) async -> Ratings?)? = nil,
                episodeRatings: (@MainActor (String, Int) async -> [Int: EpisodeRating])? = nil) {
        self.item = item
        self.catalog = catalog
        self.library = library
        self.transfers = transfers
        self.ratingsProvider = ratings
        self.episodeRatingsProvider = episodeRatings
    }

    public func load() async {
        do {
            let loaded = try await catalog.detail(item.mediaType, id: item.tmdbID)
            detail = loaded
            error = nil
            if let ratingsProvider, let imdbID = loaded.imdbID {
                ratings = await ratingsProvider(imdbID, item.mediaType)
            }
            if item.mediaType == .tv, let first = loaded.seasons.first?.number {
                // The season of the episode being watched (the latest started one), else the first.
                let watching = library.matching(tmdbID: item.tmdbID)
                    .filter { library.resumeSeconds(for: $0) >= 30 }
                    .compactMap { entry in entry.match?.season.map { ($0, entry.match?.episode ?? 0) } }
                    .max { $0 < $1 }?.0
                let start = watching.flatMap { season in loaded.seasons.contains { $0.number == season } ? season : nil } ?? first
                await selectSeason(start)
            }
        } catch let failure as AppError {
            error = failure
        } catch {
            self.error = .transport(error.localizedDescription)
        }
    }

    public func selectSeason(_ number: Int) async {
        selectedSeason = number
        episodeRatings = [:]
        async let loadedRatings = seasonRatings(number)
        let loaded = (try? await catalog.season(tvID: item.tmdbID, number: number)) ?? []
        let scores = await loadedRatings
        // A newer season pick wins over a slow response for an older one.
        guard selectedSeason == number else { return }
        episodes = loaded
        episodeRatings = scores
    }

    private func seasonRatings(_ number: Int) async -> [Int: EpisodeRating] {
        guard let episodeRatingsProvider, let imdbID = detail?.imdbID else { return [:] }
        return await episodeRatingsProvider(imdbID, number)
    }

    public func action(season: Int? = nil, episode: Int? = nil) -> TitleAction {
        if let transfer = transfers.latest(tmdbID: item.tmdbID, season: season, episode: episode) {
            switch transfer.phase {
            case .failed: return .failed(transfer)
            case .completed where transfer.playableFile != nil: break
            default: return .downloading(transfer)
            }
        }
        let hits = library.matching(tmdbID: item.tmdbID, season: season, episode: episode)
        guard let best = hits.max(by: { library.resumeSeconds(for: $0) < library.resumeSeconds(for: $1) }) else { return .get }
        let seconds = library.resumeSeconds(for: best)
        return seconds >= 30 ? .resume(best, seconds: seconds) : .play(best)
    }

    /// Whether every aired episode of the selected season is in put.io (Get season is pointless then). Any one
    /// missing, or deleted later, makes it false again.
    public func isSeasonInPutio(_ season: Int, today: Date = Date()) -> Bool {
        guard selectedSeason == season, !episodes.isEmpty else { return false }
        let day = CuratedList.day(today, plus: 0)
        let aired = episodes.filter { episode in episode.airDate.map { $0.isEmpty || $0 <= day } ?? true }
        guard !aired.isEmpty else { return false }
        return aired.allSatisfy { !library.matching(tmdbID: item.tmdbID, season: season, episode: $0.number).isEmpty }
    }

    /// What to search sources for. Needs the title's details (loaded by `load`), not an IMDb id: shows TMDB has no
    /// IMDb id for are searched by title. nil only before the details arrive, or for a show with no season picked.
    public func query(season: Int? = nil, episode: Int? = nil) -> MediaQuery? {
        guard let detail else { return nil }
        let title = detail.item.title.isEmpty ? item.title : detail.item.title
        guard !title.isEmpty else { return nil }
        let imdbID = detail.imdbID
        switch (item.mediaType, season, episode) {
        case (.tv, let season?, let episode?): return .episode(imdbID: imdbID, title: title, season: season, episode: episode)
        case (.tv, let season?, nil): return .season(imdbID: imdbID, title: title, season: season)
        case (.movie, _, _): return .movie(imdbID: imdbID, title: title, year: detail.item.year)
        default: return nil
        }
    }

    /// What to tell the user when `query` is nil (the page is still loading, or failed to).
    public var queryUnavailableMessage: String {
        error == nil ? "Still loading this title. Try again in a moment." : "Couldn't load this title, so there's nothing to search for. Check your connection and try again."
    }

    public func target(season: Int? = nil, episode: Int? = nil) -> TransferTarget {
        TransferTarget(tmdbID: item.tmdbID, kind: item.mediaType, title: detail?.item.title ?? item.title,
                       posterPath: item.posterPath, backdropPath: item.backdropPath, season: season, episode: episode)
    }
}
