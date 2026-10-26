import AMDBCore
import AMDBKit
import TVServices

/// Writes Continue Watching (Up Next cards included) and Recently Added for the Top Shelf (shown when Putio & Chill is in
/// the top row of the Home Screen) and tells tvOS to refresh it when something changed.
@MainActor
enum TVTopShelfPublisher {
    /// Changes whenever the Top Shelf's Continue Watching would: a card added or gone, or a position moved.
    static func signature(_ library: LibraryIndex) -> [String] {
        library.continueWatchingCards.map { card in
            switch card {
            case let .resume(entry): "\(card.id):\(library.resumeSeconds(for: entry))"
            case let .upNext(next): "\(card.id):\(next.label)"
            }
        }
    }

    /// `force` asks tvOS to reload the Top Shelf even when nothing changed (on leaving the app).
    static func publish(_ library: LibraryIndex, force: Bool = false) {
        let resumable = library.continueWatchingCards.prefix(10).map { card in
            switch card {
            case let .resume(entry): item(entry, resume: true)
            case let .upNext(next): item(next)
            }
        }
        var seen: Set<Int> = []
        let recent = library.recentlyAdded.filter { entry in
            guard let match = entry.match else { return false }
            return seen.insert(match.tmdbID).inserted
        }.prefix(10).map { item($0, resume: false) }
        let feed = TopShelfFeed(sections: [
            .init(title: "Continue Watching", items: Array(resumable)),
            .init(title: "Recently Added", items: Array(recent)),
        ])
        if feed.save() || force { TVTopShelfContentProvider.topShelfContentDidChange() }
    }

    /// Up Next: play starts the episode (or opens the show when it isn't in put.io); select opens the show.
    private static func item(_ next: UpNextCard) -> TopShelfFeed.Item {
        let display = DeepLink.title(tmdbID: next.tmdbID, kind: .tv).url
        return TopShelfFeed.Item(id: "cw-\(next.id)", title: "\(next.showTitle) · \(next.label)",
                                 imageURL: CatalogClient.imageURL(next.backdropPath ?? next.posterPath, size: "w780"),
                                 playLink: next.entry.map { DeepLink.play(fileID: $0.id).url } ?? display, displayLink: display)
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
