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
    var homePath: [CatalogItem] = []
    var moviesPath: [CatalogItem] = []
    var tvPath: [CatalogItem] = []
    var searchPath: [CatalogItem] = []
    var libraryPath: [CatalogItem] = []
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

    func open(_ item: CatalogItem) {
        switch tab {
        case .home: homePath.append(item)
        case .movies: moviesPath.append(item)
        case .tv: tvPath.append(item)
        case .search: searchPath.append(item)
        case .library: libraryPath.append(item)
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
