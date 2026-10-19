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
    case files(FilesFolder)
    case trash
    case imdbWatchlist
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
    /// Where to start; put.io's newest position is looked up before playing unless `startOver`.
    var resumeFrom: Int
    let played: PlayedTitle?
    let next: NextEpisode?
    var season: Int? = nil
    var episode: Int? = nil
    var source: PlaybackSource = .automatic
    /// Start exactly at `resumeFrom` (Start Over, demo screens), whatever position put.io has.
    var exactStart = false
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

    /// The title's page, unless it's already the page on screen (e.g. the player was started from it).
    func showTitle(_ item: CatalogItem) {
        if case let .title(current)? = path(of: tab).last, current.tmdbID == item.tmdbID, current.mediaType == item.mediaType { return }
        push(.title(item))
    }

    private func path(of tab: AppTab) -> [Route] {
        switch tab {
        case .home: homePath
        case .movies: moviesPath
        case .tv: tvPath
        case .search: searchPath
        case .upcoming: upcomingPath
        case .library: libraryPath
        }
    }
    func open(_ chart: IMDbChart) { push(.chart(chart)) }
    func openPerson(_ id: Int) { push(.person(id)) }
    func openCollection(_ id: Int) { push(.collection(id)) }
    func openMyList() { push(.myList) }
    func openDownloads() { push(.downloads) }
    func openFiles() { push(.files(.root)) }
    func openFolder(_ folder: FilesFolder) { push(.files(folder)) }
    func openTrash() { push(.trash) }
    func openIMDbWatchlist() { push(.imdbWatchlist) }

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

    /// Back one page in the current tab (Esc / ⌘[ on a keyboard). False when already at the tab's first page.
    @discardableResult
    func goBack() -> Bool {
        switch tab {
        case .home: homePath.popLast() != nil
        case .movies: moviesPath.popLast() != nil
        case .tv: tvPath.popLast() != nil
        case .search: searchPath.popLast() != nil
        case .upcoming: upcomingPath.popLast() != nil
        case .library: libraryPath.popLast() != nil
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

    func play(_ entry: LibraryEntry, resumeFrom: Int, next: NextEpisode? = nil, source: PlaybackSource = .automatic,
              exactStart: Bool = false) {
        let played = entry.match.map { PlayedTitle(tmdbID: $0.tmdbID, kind: $0.mediaType, title: $0.title) }
        player = PlayerRequest(file: entry.file, title: entry.displayTitle, resumeFrom: resumeFrom, played: played, next: next,
                               season: entry.match?.season, episode: entry.match?.episode, source: source, exactStart: exactStart)
    }

    func play(_ transfer: TrackedTransfer) {
        guard let file = transfer.playableFile else { return }
        let pending = transfer.pending
        let played = pending.tmdbID > 0 ? PlayedTitle(tmdbID: pending.tmdbID, kind: pending.kind, title: pending.title) : nil
        player = PlayerRequest(file: file, title: pending.title, resumeFrom: 0, played: played, next: nil,
                               season: pending.season, episode: pending.episode)
    }
}
