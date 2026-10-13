import AMDBCore
import AMDBKit
import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, movies, tv, search, library

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .tv: "TV"
        case .search: "Search"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .movies: "film"
        case .tv: "tv"
        case .search: "magnifyingglass"
        case .library: "square.stack.fill"
        }
    }
}

/// Screens that can be pushed onto a tab's navigation stack.
enum Route: Hashable {
    case title(CatalogItem)
    case chart(IMDbChart)
}

struct NextEpisode: Hashable {
    let query: MediaQuery?
    let target: TransferTarget
    let label: String
}

struct PlayerRequest: Identifiable {
    let file: PutioFile
    let title: String
    let resumeFrom: Int
    let played: PlayedTitle?
    let next: NextEpisode?
    var id: Int64 { file.id }
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
    var libraryPath: [Route] = []
    var versions: VersionsRequest?
    /// Set to start playback; cleared when the player closes.
    var player: PlayerRequest?
    /// Shown before playback when there is a saved position.
    var resumePrompt: PlayerRequest?
    var banner: Banner?
    var countdown: TrackedTransfer?
    var showSettings = false
    /// TMDB id of the title page on screen; a ready transfer for it counts down instead of showing a banner.
    var activeTitle: Int?

    func open(_ item: CatalogItem) { push(.title(item)) }
    func open(_ chart: IMDbChart) { push(.chart(chart)) }

    private func push(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .movies: moviesPath.append(route)
        case .tv: tvPath.append(route)
        case .search: searchPath.append(route)
        case .library: libraryPath.append(route)
        }
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .movies: moviesPath = []
        case .tv: tvPath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        }
    }

    func play(_ entry: LibraryEntry, resumeFrom: Int, next: NextEpisode? = nil) {
        let played = entry.match.map { PlayedTitle(tmdbID: $0.tmdbID, kind: $0.mediaType, title: $0.title) }
        player = PlayerRequest(file: entry.file, title: entry.displayTitle, resumeFrom: resumeFrom, played: played, next: next)
    }

    func play(_ transfer: TrackedTransfer) {
        guard let file = transfer.playableFile else { return }
        let pending = transfer.pending
        let played = pending.tmdbID > 0 ? PlayedTitle(tmdbID: pending.tmdbID, kind: pending.kind, title: pending.title) : nil
        player = PlayerRequest(file: file, title: pending.title, resumeFrom: 0, played: played, next: nil)
    }
}
