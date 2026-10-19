import AMDBCore
import AMDBKit
import Observation
import SwiftUI

enum TVTab: Hashable {
    case home, movies, tv, upcoming, top250, search, library, settings
    /// The sidebar's lower sections: Your Lists, Browse (genres), Surprise Me.
    case myList, imdb, files, transfers, surprise, genre(Int)

    /// The lower sections share one page history (only one is on screen at a time).
    var isExtra: Bool {
        switch self {
        case .myList, .imdb, .files, .transfers, .surprise, .genre: true
        default: false
        }
    }
}

/// Release list for a title (movie, season or episode).
struct TVVersionsRequest: Hashable {
    let query: MediaQuery
    /// nil for a free-text release search (from Search): the release's own name decides where it goes.
    let target: TransferTarget?
    let playNow: [LibraryEntry]
}

enum TVRoute: Hashable {
    case title(CatalogItem)
    case versions(TVVersionsRequest)
    case myList
    case person(Int)
    case collection(Int)
    case surprise
    case organize
    case files(FilesFolder)
    case trash
}

/// A video to play: the put.io file plus what it is (for progress, subtitles and the next episode).
struct TVPlayRequest: Identifiable {
    let entry: LibraryEntry
    /// Where to start; put.io's newest position is looked up first unless `exactStart`.
    let resumeFrom: Int
    /// Start exactly at `resumeFrom` (Start Over, demo screens), whatever position put.io has.
    var exactStart = false
    var id: Int64 { entry.id }

    var title: String { entry.match?.title ?? entry.displayTitle }
    var subtitleContext: SubtitleContext {
        SubtitleContext(fileID: entry.id, fileName: entry.file.name, title: title, tmdbID: entry.match?.tmdbID,
                        kind: entry.match?.mediaType, season: entry.match?.season, episode: entry.match?.episode)
    }
}

@Observable @MainActor
final class TVRouter {
    var tab: TVTab = .home
    var homePath: [TVRoute] = []
    var moviesPath: [TVRoute] = []
    var tvPath: [TVRoute] = []
    var searchPath: [TVRoute] = []
    var libraryPath: [TVRoute] = []
    var topPath: [TVRoute] = []
    var upcomingPath: [TVRoute] = []
    var player: TVPlayRequest?
    /// "Ready to watch" notice for a finished transfer.
    var ready: TrackedTransfer?
    /// A short message in the corner (e.g. what the folder merge moved).
    var notice: String?

    /// Pages opened from the sidebar's lower sections (Your Lists, Browse, Surprise Me).
    var listsPath: [TVRoute] = []

    func open(_ route: TVRoute) { updatePath(of: tab) { $0.append(route) } }

    func open(_ item: CatalogItem) { open(.title(item)) }

    /// Whether the tab on screen has pages pushed on it (Back then goes back a page instead of leaving the app).
    var canGoBack: Bool { tab != .settings && !currentPath.isEmpty }

    /// Back one page in the tab on screen.
    func goBack() { updatePath(of: tab) { _ = $0.popLast() } }

    /// Choosing the tab you're already on goes back to its first page; moving between the lower sections starts
    /// each one at its first page.
    func select(_ newTab: TVTab) {
        if newTab == tab, tab != .settings {
            updatePath(of: tab) { $0 = [] }
        } else if newTab.isExtra, newTab != tab {
            listsPath = []
        }
        tab = newTab
    }

    private var currentPath: [TVRoute] {
        var path: [TVRoute] = []
        // Reads only: updatePath hands back a copy.
        switch tab {
        case .home: path = homePath
        case .movies: path = moviesPath
        case .tv: path = tvPath
        case .search: path = searchPath
        case .top250: path = topPath
        case .upcoming: path = upcomingPath
        case .library, .settings: path = libraryPath
        default: path = listsPath
        }
        return path
    }

    private func updatePath(of tab: TVTab, _ change: (inout [TVRoute]) -> Void) {
        switch tab {
        case .home: change(&homePath)
        case .movies: change(&moviesPath)
        case .tv: change(&tvPath)
        case .search: change(&searchPath)
        case .top250: change(&topPath)
        case .upcoming: change(&upcomingPath)
        case .library, .settings: change(&libraryPath)
        default: change(&listsPath)
        }
    }

    /// The title's page, unless it's already the page on screen (e.g. the player was started from it).
    func showTitle(_ item: CatalogItem) {
        if case let .title(current)? = currentPath.last, current.tmdbID == item.tmdbID, current.mediaType == item.mediaType { return }
        open(.title(item))
    }

    func play(_ entry: LibraryEntry, from seconds: Int, exactStart: Bool = false) {
        player = TVPlayRequest(entry: entry, resumeFrom: seconds, exactStart: exactStart)
    }

    /// Plays a transfer that just finished on put.io.
    func playTransfer(_ transfer: TrackedTransfer) {
        guard let file = transfer.playableFile else { return }
        let pending = transfer.pending
        let match = pending.tmdbID > 0 ? LibraryMatch(tmdbID: pending.tmdbID, mediaType: pending.kind, season: pending.season,
                                                      episode: pending.episode, confidence: 1, title: pending.title,
                                                      posterPath: pending.posterPath, backdropPath: pending.backdropPath) : nil
        play(LibraryEntry(file: file, match: match, folderName: nil), from: 0)
    }
}
