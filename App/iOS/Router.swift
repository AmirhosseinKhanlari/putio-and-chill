import AMDBCore
import AMDBKit
import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, movies, tv, upcoming, search, library

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tv: "TV"
        case .upcoming: "Coming Up"
        case .search: "Search"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .tv: "tv"
        case .upcoming: "calendar"
        case .search: "magnifyingglass"
        case .library: "square.stack.fill"
        }
    }
}

/// Screens that can be pushed onto a tab's navigation stack.
enum Route: Hashable {
    case title(CatalogItem)
    case chart(IMDbChart)
    case person(Int)
    case collection(Int)
    case myList
    case downloads
}

struct NextEpisode: Hashable {
    let query: MediaQuery?
    let target: TransferTarget
    let label: String
}

/// Where a video plays from when it has been downloaded.
enum PlaybackSource {
    /// The download if there is one and Settings prefers downloads, else stream.
    case automatic, device, stream
}

struct PlayerRequest: Identifiable {
    let file: PutioFile
    let title: String
    let resumeFrom: Int
    let played: PlayedTitle?
    let next: NextEpisode?
    var season: Int? = nil
    var episode: Int? = nil
    var source: PlaybackSource = .automatic
    var id: Int64 { file.id }

    var subtitleContext: SubtitleContext {
        SubtitleContext(fileID: file.id, fileName: file.name, title: played?.title ?? title, tmdbID: played?.tmdbID,
                        kind: played?.kind, season: season, episode: episode)
    }
}

struct VersionsRequest: Identifiable {
    let id = UUID()
    let query: MediaQuery
    let target: TransferTarget?
    let playNow: [LibraryEntry]
}

enum Banner: Identifiable, Equatable {
    case ready(TrackedTransfer)
    case failed(TrackedTransfer)

    var transfer: TrackedTransfer {
        switch self {
        case let .ready(transfer), let .failed(transfer): transfer
        }
    }
    var id: Int64 { transfer.id }
}

@Observable @MainActor
final class Router {
    var tab: AppTab = .home
    var homePath: [Route] = []
    var moviesPath: [Route] = []
    var tvPath: [Route] = []
    var searchPath: [Route] = []
    var upcomingPath: [Route] = []
    var libraryPath: [Route] = []
    var versions: VersionsRequest?
    /// Set to start playback; cleared when the player closes.
    var player: PlayerRequest?
    /// Shown before playback when there is a saved position.
    var resumePrompt: PlayerRequest?
    var banner: Banner?
    var countdown: TrackedTransfer?
    var showSettings = false
    var showSurprise = false
    /// Short confirmation shown at the top (e.g. "Cleaned up 2 finished movies").
    var toast: String?
    /// TMDB id of the title page on screen; a ready transfer for it counts down instead of showing a banner.
    var activeTitle: Int?

    func open(_ item: CatalogItem) { push(.title(item)) }
    func open(_ chart: IMDbChart) { push(.chart(chart)) }
    func openPerson(_ id: Int) { push(.person(id)) }
    func openCollection(_ id: Int) { push(.collection(id)) }
    func openMyList() { push(.myList) }
    func openDownloads() { push(.downloads) }

    private func push(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .movies: moviesPath.append(route)
        case .tv: tvPath.append(route)
        case .search: searchPath.append(route)
        case .upcoming: upcomingPath.append(route)
        case .library: libraryPath.append(route)
        }
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .movies: moviesPath = []
        case .tv: tvPath = []
        case .search: searchPath = []
        case .upcoming: upcomingPath = []
        case .library: libraryPath = []
        }
    }

    func play(_ entry: LibraryEntry, resumeFrom: Int, next: NextEpisode? = nil, source: PlaybackSource = .automatic) {
        let played = entry.match.map { PlayedTitle(tmdbID: $0.tmdbID, kind: $0.mediaType, title: $0.title) }
        player = PlayerRequest(file: entry.file, title: entry.displayTitle, resumeFrom: resumeFrom, played: played, next: next,
                               season: entry.match?.season, episode: entry.match?.episode, source: source)
    }

    func play(_ transfer: TrackedTransfer) {
        guard let file = transfer.playableFile else { return }
        let pending = transfer.pending
        let played = pending.tmdbID > 0 ? PlayedTitle(tmdbID: pending.tmdbID, kind: pending.kind, title: pending.title) : nil
        player = PlayerRequest(file: file, title: pending.title, resumeFrom: 0, played: played, next: nil,
                               season: pending.season, episode: pending.episode)
    }
}
