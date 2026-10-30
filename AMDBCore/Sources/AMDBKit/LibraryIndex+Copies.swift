import AMDBCore
import Foundation

/// Copies of one title (another quality, another release): switching versions partway through keeps watching from
/// where the last one was left. Positions stay per file, here and in put.io; the carried position only decides where
/// a copy starts, and that copy then saves its own as usual.
extension LibraryIndex {
    /// The copies of a title in the library: the same movie, or the same episode of a show. Empty for a show's file
    /// that isn't one episode (nothing to carry between those).
    public func copies(tmdbID: Int, kind: MediaKind, season: Int?, episode: Int?) -> [LibraryEntry] {
        if kind == .tv, season == nil || episode == nil { return [] }
        return entries.filter { entry in
            guard let match = entry.match, match.tmdbID == tmdbID, match.mediaType == kind else { return false }
            return kind == .movie || (match.season == season && match.episode == episode)
        }
    }

    /// The other copies of `entry`'s title (not `entry` itself).
    public func otherCopies(of entry: LibraryEntry) -> [LibraryEntry] {
        guard let match = entry.match else { return [] }
        return copies(tmdbID: match.tmdbID, kind: match.mediaType, season: match.season, episode: match.episode)
            .filter { $0.id != entry.id }
    }

    /// The copy watched most recently (when its position was saved, on any device), else the furthest one; nil when
    /// none of them was really started (`Watched.rewatchSeconds`, as in Continue Watching) or watched. A short peek at
    /// a copy doesn't count: it must not hide where the real watching was left.
    public func lastWatchedCopy(_ copies: [LibraryEntry]) -> LibraryEntry? {
        var best: (entry: LibraryEntry, order: (Date, Int), seconds: Int)?
        for copy in copies {
            let seconds = resumeSeconds(for: copy)
            guard hasPosition(copy, seconds: seconds) else { continue }
            let order = watchOrder(copy.id)
            if let current = best, order != current.order ? order < current.order : seconds < current.seconds { continue }
            best = (copy, order, seconds)
        }
        return best?.entry
    }

    /// Where to start `entry` when it's played to resume: its own position, unless another copy of the same title
    /// was watched more recently; then that copy's position (switching from the 1080p to the 4K halfway through
    /// goes on from there). A copy watched to the end more recently starts this one from the beginning, not at an
    /// older position of its own; so does a carried position this copy is too short for.
    public func resumeSeconds(forTitleOf entry: LibraryEntry) -> Int {
        let own = entries.first { $0.id == entry.id } ?? entry
        let ownSeconds = resumeSeconds(for: own)
        guard let latest = lastWatchedCopy(otherCopies(of: own)) else { return ownSeconds }
        if hasPosition(own, seconds: ownSeconds), watchOrder(latest.id) <= watchOrder(own.id) { return ownSeconds }
        if isWatched(latest) { return 0 }
        let carried = resumeSeconds(for: latest)
        if let length = durations[own.id] ?? own.file.duration, length > 0,
           carried >= length || Watched.isReached(position: Double(carried), duration: Double(length)) {
            return 0
        }
        return carried
    }

    /// `resumeSeconds(forTitleOf:)` with put.io's current positions for every copy, when it answers within `timeout`
    /// (any of them may have been watched on another device since).
    public func freshResumeSeconds(forTitleOf entry: LibraryEntry, timeout: Duration = .seconds(2)) async -> Int {
        await checkPositions([entry.id] + otherCopies(of: entry).map(\.id), timeout: timeout)
        return resumeSeconds(forTitleOf: entry)
    }

    /// Started for real (at least `Watched.rewatchSeconds`), or watched to the end.
    private func hasPosition(_ entry: LibraryEntry, seconds: Int) -> Bool { seconds >= Watched.rewatchSeconds || isWatched(entry) }

    /// How recently a file was watched: when, on any device, then this session's order.
    private func watchOrder(_ id: Int64) -> (Date, Int) { (positions[id]?.watchedAt ?? .distantPast, touchedOrder[id] ?? -1) }
}
