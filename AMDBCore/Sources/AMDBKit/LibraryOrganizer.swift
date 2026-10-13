import AMDBCore
import Foundation

/// One planned move: a video, or the release folder holding it, into its Movies / TV folder.
public struct OrganizeMove: Sendable, Hashable, Identifiable {
    /// The put.io file or folder to move.
    public let itemID: Int64
    public let name: String
    public let isFolder: Bool
    public let kind: MediaKind
    public let title: String
    public let season: Int?
    /// Where it goes, e.g. "AMDB/TV/Severance/Season 2".
    public let destination: String
    public var id: Int64 { itemID }
}

public struct OrganizePlan: Sendable, Equatable {
    public var moves: [OrganizeMove]
    /// Videos already where they belong.
    public var inPlace: Int
    /// Videos left alone because the app isn't sure what they are.
    public var unrecognized: [LibraryEntry]

    public var isEmpty: Bool { moves.isEmpty }
}

/// Moves files that arrived outside AMDB (chill's site, put.io directly, older downloads) into the folder layout
/// from Settings. Only confidently recognized videos move; release folders move whole so subtitle files stay
/// next to their video; folders the layout lives in are never moved.
public enum LibraryOrganizer {
    public static let minimumConfidence = 0.75

    /// `tree` (from the last library walk) lets planning run without listing put.io again.
    public static func plan(entries: [LibraryEntry], layout: FolderLayout, putio: any PutioService,
                            store: LocalStore, tree: FolderTree? = nil) async throws -> OrganizePlan {
        var moves: [OrganizeMove] = []
        var inPlace = 0
        var unrecognized: [LibraryEntry] = []
        var destinations: [String: Int64?] = [:]
        var folders: [Int64: PutioFile] = [:]
        let protected = try await protectedFolders(layout: layout, putio: putio, store: store, tree: tree)

        func destinationID(_ entry: LibraryEntry) async throws -> Int64? {
            guard let match = entry.match else { return nil }
            let key = layout.displayPath(kind: match.mediaType, title: match.title, season: match.season)
            if let cached = destinations[key] { return cached }
            let id = try await layout.existingDestinationID(kind: match.mediaType, title: match.title, season: match.season,
                                                            putio: putio, store: store, tree: tree)
            destinations[key] = id
            return id
        }

        func folder(_ id: Int64) async throws -> PutioFile? {
            if let cached = folders[id] { return cached }
            if let known = tree?.folders[id] { return known }
            guard let fetched = try? await putio.file(id: id) else { return nil }
            folders[id] = fetched
            return fetched
        }

        /// The show's own folder (base/Show) — moving it would move the whole show.
        func isShowFolder(_ folderID: Int64, match: LibraryMatch) async throws -> Bool {
            guard match.mediaType == .tv else { return false }
            let show = try await FolderLayout(movies: layout.movies, tv: layout.tv, seasonFolders: false)
                .existingDestinationID(kind: .tv, title: match.title, season: nil, putio: putio, store: store, tree: tree)
            return show == folderID
        }

        func move(_ item: (id: Int64, name: String, isFolder: Bool), for match: LibraryMatch) -> OrganizeMove {
            OrganizeMove(itemID: item.id, name: item.name, isFolder: item.isFolder, kind: match.mediaType, title: match.title,
                         season: match.season,
                         destination: layout.displayPath(kind: match.mediaType, title: match.title, season: match.season))
        }

        let groups = Dictionary(grouping: entries) { $0.file.parentId ?? 0 }
        for parentID in groups.keys.sorted() {
            let group = groups[parentID] ?? []
            let recognized = group.filter(isConfident)
            unrecognized += group.filter { !recognized.contains($0) }
            guard !recognized.isEmpty else { continue }

            // Where each recognized video should live.
            var targets: [Int64: Int64?] = [:]
            for entry in recognized { targets[entry.id] = try await destinationID(entry) }
            let paths = Set(recognized.compactMap { $0.match.map { layout.displayPath(kind: $0.mediaType, title: $0.title, season: $0.season) } })

            let parent = parentID == 0 ? nil : try await folder(parentID)
            let sameDestination = paths.count == 1 && recognized.count == group.count
            let destination = recognized.first.flatMap { targets[$0.id] } ?? nil

            // Already there: the video sits in its destination, or in a release folder inside it.
            if sameDestination, let destination, parentID == destination || parent?.parentId == destination {
                inPlace += recognized.count
                continue
            }

            // A release folder holding only this title moves whole (keeps subtitles and extras with the video).
            // Only folders named like a release of that title: never "Downloads", a show folder, or the layout itself.
            if sameDestination, let parent, !protected.contains(parentID), !isDestination(parentID, targets),
               let match = recognized.first?.match, looksLikeRelease(parent.name, of: match),
               try await !isShowFolder(parentID, match: match) {
                moves.append(move((parent.id, parent.name, true), for: match))
                continue
            }

            // Otherwise move the videos one by one.
            for entry in recognized {
                guard let match = entry.match else { continue }
                if let target = targets[entry.id] ?? nil, target == parentID {
                    inPlace += 1
                    continue
                }
                moves.append(move((entry.id, entry.file.name, false), for: match))
            }
        }
        moves.sort { ($0.destination, $0.name) < ($1.destination, $1.name) }
        return OrganizePlan(moves: moves, inPlace: inPlace, unrecognized: unrecognized)
    }

    /// Runs the plan: creates destination folders as needed and moves items in one call per folder.
    /// Returns how many items moved.
    @discardableResult
    public static func apply(_ plan: OrganizePlan, layout: FolderLayout, putio: any PutioService, store: LocalStore) async throws -> Int {
        var moved = 0
        let byDestination = Dictionary(grouping: plan.moves) { $0.destination }
        for destination in byDestination.keys.sorted() {
            guard let items = byDestination[destination], let first = items.first else { continue }
            let folderID = try await layout.destinationID(kind: first.kind, title: first.title, season: first.season,
                                                          putio: putio, store: store)
            let ids = items.map(\.itemID).filter { $0 != folderID }
            guard !ids.isEmpty else { continue }
            try await putio.moveFiles(ids: ids, to: folderID)
            moved += ids.count
        }
        return moved
    }

    /// A match good enough to move: high confidence, and the name carries release evidence — a year that agrees
    /// with the movie, or a season/episode for shows. Course videos, home videos and the like stay put.
    static func isConfident(_ entry: LibraryEntry) -> Bool {
        guard let match = entry.match, match.confidence >= minimumConfidence else { return false }
        let names = [entry.file.name, entry.folderName].compactMap { $0 }.map(ReleaseNameParser.parse)
        switch match.mediaType {
        case .movie:
            guard let year = names.compactMap(\.year).first else { return false }
            return match.year.map { abs($0 - year) <= 1 } ?? true
        case .tv:
            return names.contains { $0.season != nil || $0.episode != nil }
        default:
            return false
        }
    }

    static func looksLikeRelease(_ folderName: String, of match: LibraryMatch) -> Bool {
        let title = LibraryMatcher.normalize(match.title)
        let parsed = LibraryMatcher.normalize(ReleaseNameParser.parse(folderName).title)
        guard !title.isEmpty, !parsed.isEmpty else { return false }
        // The folder must carry release details too, so a plain "Severance" (a show folder) doesn't count.
        let details = ReleaseNameParser.parse(folderName)
        let hasReleaseDetails = details.year != nil || details.season != nil || details.resolution != .unknown
        return hasReleaseDetails && (parsed == title || parsed.hasPrefix(title) || title.hasPrefix(parsed))
    }

    private static func isDestination(_ folderID: Int64, _ targets: [Int64: Int64?]) -> Bool {
        targets.values.contains { $0 == folderID }
    }

    /// The base folders and every folder above them: moving any of these would carry the layout with it.
    private static func protectedFolders(layout: FolderLayout, putio: any PutioService, store: LocalStore,
                                         tree: FolderTree?) async throws -> Set<Int64> {
        var result: Set<Int64> = [0]
        var starts: [Int64] = []
        for kind in [MediaKind.movie, .tv] {
            if let id = try await layout.existingBaseID(kind, putio: putio, store: store, tree: tree) { starts.append(id) }
        }
        for start in starts {
            var current: Int64? = start
            var steps = 0
            while let id = current, id != 0, steps < 20 {
                result.insert(id)
                if let known = tree?.folders[id] {
                    current = known.parentId
                } else {
                    current = (try? await putio.file(id: id))?.parentId
                }
                steps += 1
            }
        }
        return result
    }
}
