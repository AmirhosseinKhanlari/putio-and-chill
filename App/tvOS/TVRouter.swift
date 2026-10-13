import AMDBCore
import AMDBKit
import Observation
import SwiftUI

enum TVTab: Hashable { case home, movies, tv, search, library, settings }

/// Release list for a title (movie, season or episode).
struct TVVersionsRequest: Hashable {
    let query: MediaQuery
    let target: TransferTarget
    let playNow: [LibraryEntry]
}

enum TVRoute: Hashable {
    case title(CatalogItem)
    case versions(TVVersionsRequest)
    case myList
}

/// A video to play: the put.io file plus what it is (for progress, subtitles and the next episode).
struct TVPlayRequest: Identifiable {
    let entry: LibraryEntry
    let resumeFrom: Int
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
    var player: TVPlayRequest?

    func open(_ route: TVRoute) {
        switch tab {
        case .home: homePath.append(route)
        case .movies: moviesPath.append(route)
        case .tv: tvPath.append(route)
        case .search: searchPath.append(route)
        case .library, .settings: libraryPath.append(route)
        }
    }

    func open(_ item: CatalogItem) { open(.title(item)) }

    func play(_ entry: LibraryEntry, from seconds: Int) {
        player = TVPlayRequest(entry: entry, resumeFrom: seconds)
    }
}
