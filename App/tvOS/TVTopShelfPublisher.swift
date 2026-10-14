import AMDBCore
import AMDBKit
import TVServices

/// Writes Continue Watching and Recently Added for the Top Shelf (shown when AMDB is in the top row of the Home
/// Screen) and tells tvOS to refresh it when something changed.
@MainActor
enum TVTopShelfPublisher {
    static func publish(_ library: LibraryIndex) {
        let resumable = library.continueWatching.prefix(10).map { item($0, resume: true) }
        var seen: Set<Int> = []
        let recent = library.recentlyAdded.filter { entry in
            guard let match = entry.match else { return false }
            return seen.insert(match.tmdbID).inserted
        }.prefix(10).map { item($0, resume: false) }
        let feed = TopShelfFeed(sections: [
            .init(title: "Continue Watching", items: Array(resumable)),
            .init(title: "Recently Added", items: Array(recent)),
        ])
        if feed.save() { TVTopShelfContentProvider.topShelfContentDidChange() }
    }

    private static func item(_ entry: LibraryEntry, resume: Bool) -> TopShelfFeed.Item {
        let match = entry.match
        let episode = match.flatMap { match in match.season.map { "S\($0)" + (match.episode.map { " E\($0)" } ?? "") } }
        let title = [match?.title ?? entry.displayTitle, resume ? episode : nil].compactMap { $0 }.joined(separator: " · ")
        let play = DeepLink.play(fileID: entry.id).url
        let display = match.map { DeepLink.title(tmdbID: $0.tmdbID, kind: $0.mediaType).url } ?? play
        return TopShelfFeed.Item(id: "\(resume ? "cw" : "new")-\(entry.id)", title: title,
                                 imageURL: CatalogClient.imageURL(match?.backdropPath ?? match?.posterPath, size: "w780"),
                                 playLink: play, displayLink: display)
    }
}
