import AMDBCore
import Foundation

/// A title the user picked for some files with Fix Match, used instead of automatic matching.
public struct MatchOverride: Codable, Sendable, Hashable {
    public let tmdbID: Int
    public let mediaType: MediaKind
    public let title: String
    public let year: Int?
    public let posterPath: String?
    public let backdropPath: String?
    /// Shows: the season these files are, whatever their names say ("Monster.2022.S03E01" is season 1 of
    /// "Monster: The Ed Gein Story"). nil keeps the season in each name.
    public let season: Int?

    public init(item: CatalogItem, season: Int? = nil) {
        tmdbID = item.tmdbID; mediaType = item.mediaType; title = item.title; year = item.year
        posterPath = item.posterPath; backdropPath = item.backdropPath
        self.season = item.mediaType == .tv ? season : nil
    }

    /// The library match for one file. Episodes come from the file name (as in season packs); a show file without a
    /// season in its name is season 1.
    public func match(fileName: String) -> LibraryMatch {
        guard mediaType == .tv else {
            return LibraryMatch(tmdbID: tmdbID, mediaType: .movie, season: nil, episode: nil, confidence: 1,
                                title: title, year: year, posterPath: posterPath, backdropPath: backdropPath)
        }
        let found = EpisodeNumbering.episode(in: fileName)
        let named = found?.season ?? ReleaseNameParser.parse(fileName).season
        return LibraryMatch(tmdbID: tmdbID, mediaType: .tv, season: season ?? named ?? 1, episode: found?.episode,
                            confidence: 1, title: title, year: year, posterPath: posterPath, backdropPath: backdropPath)
    }
}

/// Fix Match choices, kept on the device and applied on every library update before automatic matching.
public struct MatchOverrides: Codable, Sendable, Equatable {
    /// put.io file id → title.
    public var files: [Int64: MatchOverride] = [:]
    /// put.io folder id → title, for every video anywhere below that folder.
    public var folders: [Int64: MatchOverride] = [:]
    /// `nameKey` → title, for every video named like it (same title and season), including ones added later.
    public var names: [String: MatchOverride] = [:]

    public init() {}

    public var isEmpty: Bool { files.isEmpty && folders.isEmpty && names.isEmpty }

    /// The override for a file: its own first, then the nearest folder above it, then its name.
    /// `folderIDs` are the folders it sits in, nearest first.
    public func override(for file: PutioFile, folderIDs: [Int64]) -> MatchOverride? {
        if let own = files[file.id] { return own }
        for id in folderIDs { if let folder = folders[id] { return folder } }
        return Self.nameKey(file.name).flatMap { names[$0] }
    }

    /// "Monster.2022.S03E05.1080p.mkv" → "monster|2022|s3": the parsed title (with its year, which tells same-named
    /// shows apart) and season, so every episode of that season, and no other, shares it. nil when there's no title.
    public static func nameKey(_ fileName: String) -> String? {
        let parsed = ReleaseNameParser.parse(fileName)
        let title = LibraryMatcher.normalize(parsed.title)
        guard !title.isEmpty else { return nil }
        return [title, parsed.year.map(String.init) ?? "", parsed.season.map { "s\($0)" } ?? "movie"].joined(separator: "|")
    }
}

/// What a Fix Match applies to.
public enum FixMatchTarget: Sendable, Hashable {
    /// These videos (one, or every file of a Library card).
    case files([PutioFile])
    /// Every video anywhere below a folder.
    case folder(id: Int64, name: String)
    /// Every video named like this one (same title and season), now and later.
    case sameName(String)

    /// For the scope picker.
    public var label: String {
        switch self {
        case let .files(files): return files.count == 1 ? "This file only" : "These \(files.count) files"
        case let .folder(_, name): return "Everything in \u{201C}\(name)\u{201D}"
        case let .sameName(name):
            let parsed = ReleaseNameParser.parse(name)
            let season = parsed.season.map { " season \($0)" } ?? ""
            let title = [parsed.title, parsed.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
            return "All files named \u{201C}\(title)\u{201D}\(season)"
        }
    }
}

extension FolderTree {
    /// The folders a file in `parentID` sits in, nearest first (as far up as the last library walk saw).
    public func chain(from parentID: Int64?) -> [Int64] {
        var chain: [Int64] = []
        var current = parentID
        while let id = current, id != 0, !chain.contains(id) {
            chain.append(id)
            current = folders[id]?.parentId
        }
        return chain
    }
}
