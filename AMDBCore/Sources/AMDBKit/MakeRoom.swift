import AMDBCore
import Foundation

/// Whether a download fits in put.io's free space.
public enum SpaceCheck {
    /// Free space must cover the download plus this many percent of it: release sizes are rounded, and a torrent
    /// brings subtitles and artwork along.
    public static let marginPercent: Int64 = 2

    /// The free space a download of `size` needs (whole bytes, rounded up).
    public static func required(size: Int64) -> Int64 { size + (size * marginPercent + 99) / 100 }

    /// Bytes still missing for a download of `size` to fit in `avail`. nil when it fits, or when either is unknown
    /// (an unknown size is never checked: the download is sent and put.io decides).
    public static func shortfall(size: Int64?, avail: Int64?) -> Int64? {
        guard let size, size > 0, let avail else { return nil }
        let missing = required(size: size) - avail
        return missing > 0 ? missing : nil
    }
}

/// put.io's wording for a transfer that failed because the account is full. It isn't documented, so this matches
/// leniently: "not enough (disk) space", "insufficient storage", "no space left", "disk full", "quota exceeded"…
public enum OutOfSpace {
    private static let patterns = [
        #"\b(not enough|insufficient|no|out of|lack of|low on)\b[^.]{0,20}\b(space|storage|disk|quota)\b"#,
        #"\b(disk|storage|space|quota)\b[^.]{0,20}\b(full|exceeded|exhausted|used up)\b"#,
        #"\bexceed(s|ed|ing)?\b[^.]{0,30}\b(space|storage|disk|quota)\b"#,
    ]

    public static func matches(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return patterns.contains { message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A failed transfer whose error says put.io ran out of space.
    public static func matches(_ tracked: TrackedTransfer) -> Bool {
        guard case let .failed(message) = tracked.phase else { return false }
        return matches(message) || matches(tracked.transfer?.errorMessage)
    }
}

/// One thing that can go to make room: a movie (its folder, or the file when it sits loose), a season (its folder),
/// or one episode (when its season has no folder of its own).
public struct RoomCandidate: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case movie, season, episode, other }

    /// The put.io file or folder that is deleted.
    public let id: Int64
    public let isFolder: Bool
    /// Its name in put.io.
    public let name: String
    public let title: String
    public let posterPath: String?
    public let kind: Kind
    public let season: Int?
    public let episode: Int?
    public let size: Int64
    /// Every video in it was watched to the end.
    public let watched: Bool
    /// When put.io got it (the folder's or file's created date).
    public let addedAt: Date?
    /// The library's videos inside (the ones a folder may hold; checked again before deleting).
    public let fileIDs: [Int64]

    public init(id: Int64, isFolder: Bool, name: String, title: String, posterPath: String?, kind: Kind, season: Int?,
                episode: Int?, size: Int64, watched: Bool, addedAt: Date?, fileIDs: [Int64]) {
        self.id = id; self.isFolder = isFolder; self.name = name; self.title = title; self.posterPath = posterPath
        self.kind = kind; self.season = season; self.episode = episode; self.size = size; self.watched = watched
        self.addedAt = addedAt; self.fileIDs = fileIDs
    }

    /// "Season 2", "S2 E4", nil for a movie.
    public var detail: String? {
        switch (season, episode) {
        case let (season?, episode?): "S\(season) E\(episode)"
        case let (season?, nil): "Season \(season)"
        default: nil
        }
    }
}

/// What could be deleted to make room, in the order it goes, and the fewest from the front that free enough.
public struct RoomPlan: Sendable, Hashable {
    /// Bytes to free.
    public let needed: Int64
    /// Everything allowed to go, in order: watched first, then unwatched; oldest added first within each.
    public let candidates: [RoomCandidate]
    /// The suggestion: the fewest candidates from the front that free `needed`. Empty when even all of them can't.
    public let suggested: Set<Int64>

    public init(needed: Int64, candidates: [RoomCandidate]) {
        self.needed = needed
        self.candidates = candidates
        var picked: Set<Int64> = []
        var freed: Int64 = 0
        for candidate in candidates where freed < needed {
            picked.insert(candidate.id)
            freed += candidate.size
        }
        suggested = freed >= needed ? picked : []
    }

    /// Everything allowed, together.
    public var available: Int64 { candidates.reduce(0) { $0 + $1.size } }
    /// Whether deleting everything allowed would be enough.
    public var isEnough: Bool { available >= needed }

    /// The candidates picked in `selection`, in plan order. Ids that aren't candidates are ignored.
    public func chosen(_ selection: Set<Int64>) -> [RoomCandidate] { candidates.filter { selection.contains($0.id) } }

    public func freed(_ selection: Set<Int64>) -> Int64 { chosen(selection).reduce(0) { $0 + $1.size } }
}

/// Builds the make-room plan from the library. Pure, so every rule is tested without put.io.
///
/// Rules: only what's inside the top-level Movies and TV Series folders; never a title being watched (a position of
/// 30 s or more and not watched to the end), on My List, or the one being got (for a show, the season being got);
/// never a folder a download is saving into. A folder goes whole only when all the library's videos in it are one
/// movie or one season (and it holds no folder the library knows nothing about); otherwise each video goes alone.
public enum RoomPlanner {
    public struct Rules: Sendable {
        /// Files watched to the end.
        public var watched: Set<Int64>
        /// Resume positions in seconds.
        public var positions: [Int64: Int]
        /// My List (`SavedTitle.id`s: "movie-603", "tv-1399").
        public var myList: Set<String>
        /// What's being got: the same movie, or the same show's season, is kept.
        public var target: TransferTarget?
        /// Folders downloads are saving into: they, and the folders holding them, are kept.
        public var busyFolders: Set<Int64>
        public var topLevelFolders: [String]

        public init(watched: Set<Int64> = [], positions: [Int64: Int] = [:], myList: Set<String> = [],
                    target: TransferTarget? = nil, busyFolders: Set<Int64> = [],
                    topLevelFolders: [String] = [DefaultFolders.movies, DefaultFolders.tv]) {
            self.watched = watched; self.positions = positions; self.myList = myList; self.target = target
            self.busyFolders = busyFolders; self.topLevelFolders = topLevelFolders
        }
    }

    /// The position from which a video counts as being watched.
    public static let inProgressSeconds = 30

    public static func plan(needed: Int64, entries: [LibraryEntry], folders: [PutioFile], rules: Rules) -> RoomPlan {
        RoomPlan(needed: needed, candidates: candidates(entries: entries, folders: folders, rules: rules))
    }

    public static func candidates(entries: [LibraryEntry], folders: [PutioFile], rules: Rules) -> [RoomCandidate] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childFolders = Dictionary(grouping: folders.filter { $0.parentId != nil }) { $0.parentId ?? 0 }
        let roots = Set(folders.filter { folder in
            (folder.parentId ?? 0) == 0 && rules.topLevelFolders.contains { DefaultFolders.sameName($0, folder.name) }
        }.map(\.id))

        // Each video's folders below Movies / TV Series, nearest first; nil when it isn't inside one of them.
        func chain(_ entry: LibraryEntry) -> [Int64]? {
            var path: [Int64] = []
            var current = entry.file.parentId
            while let id = current, path.count < 64 {
                if roots.contains(id) { return path }
                guard id != 0, let folder = byID[id] else { return nil }
                path.append(id)
                current = folder.parentId
            }
            return nil
        }

        var chains: [Int64: [Int64]] = [:]
        var keysUnder: [Int64: Set<String>] = [:]
        for entry in entries {
            guard let path = chain(entry) else { continue }
            chains[entry.id] = path
            for folder in path { keysUnder[folder, default: []].insert(key(entry)) }
        }

        // Downloads' folders and every folder above them.
        var busy: Set<Int64> = []
        for id in rules.busyFolders {
            var current: Int64? = id
            while let folder = current, folder != 0, busy.insert(folder).inserted { current = byID[folder]?.parentId }
        }

        // Every folder inside holds library videos, or only subtitles / samples / artwork.
        func onlyKnownFolders(_ id: Int64, depth: Int = 0) -> Bool {
            guard depth < 32 else { return false }
            return (childFolders[id] ?? []).allSatisfy { child in
                if LibraryIndex.isSkippedFolder(child.name) { return true }
                return keysUnder[child.id] != nil && onlyKnownFolders(child.id, depth: depth + 1)
            }
        }
        func wholeFolder(_ id: Int64) -> Bool {
            keysUnder[id]?.count == 1 && !busy.contains(id) && onlyKnownFolders(id)
        }

        // Group: the highest folder that is wholly this one movie or season, else the video itself.
        var groups: [Int64: (isFolder: Bool, entries: [LibraryEntry])] = [:]
        var order: [Int64] = []
        for entry in entries {
            guard let path = chains[entry.id] else { continue }
            let folder = path.reversed().first(where: wholeFolder)
            let id = folder ?? entry.id
            if groups[id] == nil { order.append(id); groups[id] = (folder != nil, []) }
            groups[id]?.entries.append(entry)
        }

        let candidates: [RoomCandidate] = order.compactMap { id in
            guard let group = groups[id] else { return nil }
            let items = group.entries
            // What's kept.
            if items.contains(where: { isInProgress($0, rules) || isOnMyList($0, rules) || isTarget($0, rules) }) { return nil }
            let file = group.isFolder ? byID[id] : items.first?.file
            guard let file else { return nil }
            let videosSize = items.compactMap(\.file.size).reduce(0, +)
            let size = group.isFolder ? max(file.size ?? 0, videosSize) : (file.size ?? 0)
            // Unknown size: deleting it can't be promised to help.
            guard size > 0 else { return nil }
            let match = items.first { $0.match != nil }?.match
            let kind: RoomCandidate.Kind
            switch match?.mediaType {
            case .movie?: kind = .movie
            case .tv?: kind = group.isFolder ? .season : .episode
            default: kind = .other
            }
            let fallbackTitle = group.isFolder ? file.name : (file.name as NSString).deletingPathExtension
            return RoomCandidate(
                id: id, isFolder: group.isFolder, name: file.name, title: match?.title ?? fallbackTitle,
                posterPath: match?.posterPath, kind: kind, season: kind == .season || kind == .episode ? match?.season : nil,
                episode: kind == .episode ? match?.episode : nil, size: size,
                watched: items.allSatisfy { rules.watched.contains($0.id) }, addedAt: PutioDate.parse(file.createdAt),
                fileIDs: items.map(\.id))
        }
        return candidates.sorted(by: deletedFirst)
    }

    /// Watched before unwatched; within each, oldest added first (no date: last); then by id, so the order is stable.
    static func deletedFirst(_ a: RoomCandidate, _ b: RoomCandidate) -> Bool {
        if a.watched != b.watched { return a.watched }
        switch (a.addedAt, b.addedAt) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.id < b.id
        }
    }

    /// Videos of one movie, or of one season of a show, share a key; a video with no match is its own.
    static func key(_ entry: LibraryEntry) -> String {
        guard let match = entry.match else { return "file-\(entry.id)" }
        switch match.mediaType {
        case .tv: return "tv-\(match.tmdbID)-s\(match.season ?? -1)"
        default: return "\(match.mediaType.rawValue)-\(match.tmdbID)"
        }
    }

    static func isInProgress(_ entry: LibraryEntry, _ rules: Rules) -> Bool {
        let seconds = rules.positions[entry.id] ?? entry.startFrom
        return seconds >= inProgressSeconds && !rules.watched.contains(entry.id)
    }

    static func isOnMyList(_ entry: LibraryEntry, _ rules: Rules) -> Bool {
        guard let match = entry.match else { return false }
        return rules.myList.contains("\(match.mediaType.rawValue)-\(match.tmdbID)")
    }

    static func isTarget(_ entry: LibraryEntry, _ rules: Rules) -> Bool {
        guard let target = rules.target, let match = entry.match, target.tmdbID > 0,
              match.tmdbID == target.tmdbID, match.mediaType == target.kind else { return false }
        guard target.kind == .tv, let season = target.season, let entrySeason = match.season else { return true }
        return season == entrySeason
    }
}
