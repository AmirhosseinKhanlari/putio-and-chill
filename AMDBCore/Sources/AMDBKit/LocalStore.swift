import AMDBCore
import Foundation

public struct PendingTransfer: Codable, Sendable, Hashable, Identifiable {
    public let transferID: Int64
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public let posterPath: String?
    public let backdropPath: String?
    public let season: Int?
    public let episode: Int?
    public let createdAt: Date

    public var id: Int64 { transferID }

    public init(transferID: Int64, tmdbID: Int, kind: MediaKind, title: String, posterPath: String?,
                backdropPath: String?, season: Int?, episode: Int?, createdAt: Date) {
        self.transferID = transferID; self.tmdbID = tmdbID; self.kind = kind; self.title = title
        self.posterPath = posterPath; self.backdropPath = backdropPath; self.season = season
        self.episode = episode; self.createdAt = createdAt
    }
}

public struct PlayedTitle: Codable, Sendable, Hashable {
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public init(tmdbID: Int, kind: MediaKind, title: String) { self.tmdbID = tmdbID; self.kind = kind; self.title = title }
}

/// A title saved to My List (enough to draw a poster without another TMDB call).
public struct SavedTitle: Codable, Sendable, Hashable, Identifiable {
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public let posterPath: String?
    public let backdropPath: String?
    public let year: Int?

    public init(_ item: CatalogItem) {
        tmdbID = item.tmdbID; kind = item.mediaType; title = item.title
        posterPath = item.posterPath; backdropPath = item.backdropPath; year = item.year
    }

    public var id: String { "\(kind.rawValue)-\(tmdbID)" }
    public var catalogItem: CatalogItem {
        CatalogItem(tmdbID: tmdbID, mediaType: kind, title: title, posterPath: posterPath, backdropPath: backdropPath, year: year)
    }
}

/// A movie played to the end in AMDB (auto-clean only ever considers these).
public struct FinishedFile: Codable, Sendable, Hashable {
    public let fileID: Int64
    public let at: Date
    public init(fileID: Int64, at: Date) { self.fileID = fileID; self.at = at }
}

public enum DownloadState: Codable, Sendable, Hashable {
    case queued
    case downloading(progress: Double)
    /// Path relative to the app's home directory (the container path changes between launches).
    case done(relativePath: String)
    case failed(message: String)
}

/// An offline copy of a put.io video on this device.
public struct DownloadRecord: Codable, Sendable, Hashable, Identifiable {
    public let fileID: Int64
    public let title: String
    public let posterPath: String?
    public let tmdbID: Int?
    public let kind: MediaKind?
    public let season: Int?
    public let episode: Int?
    public var state: DownloadState

    public init(fileID: Int64, title: String, posterPath: String?, tmdbID: Int?, kind: MediaKind?,
                season: Int?, episode: Int?, state: DownloadState) {
        self.fileID = fileID; self.title = title; self.posterPath = posterPath; self.tmdbID = tmdbID
        self.kind = kind; self.season = season; self.episode = episode; self.state = state
    }

    public var id: Int64 { fileID }
}

public struct LocalState: Codable, Sendable, Equatable {
    public var matches: [Int64: LibraryMatch] = [:]
    public var unmatched: Set<Int64> = []
    /// When each file was found to have no match (older builds didn't record it: those are retried).
    public var unmatchedAt: [Int64: Date] = [:]
    public var pending: [PendingTransfer] = []
    public var recentSearches: [String] = []
    public var lastPlayed: PlayedTitle?
    public var folderIDs: [String: Int64] = [:]
    public var myList: [SavedTitle] = []
    public var finished: [FinishedFile] = []
    public var downloads: [DownloadRecord] = []
    /// OpenSubtitles pick per put.io file ID.
    public var subtitleChoices: [Int64: SubtitleChoice] = [:]
    /// The IMDb watchlist as last loaded (shown at once, and offline).
    public var imdbWatchlist: [SavedTitle] = []
    /// IMDb id → TMDB title, so each watchlist title is looked up once.
    public var imdbMatches: [String: SavedTitle] = [:]
    /// Shows whose new episodes send a notification.
    public var followedShows: [SavedTitle] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
        case matches, unmatched, unmatchedAt, pending, recentSearches, lastPlayed, folderIDs, myList, finished, downloads, subtitleChoices
        case imdbWatchlist, imdbMatches, followedShows
    }

    /// Every field is optional on disk, so files written by older versions keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matches = try c.decodeIfPresent([Int64: LibraryMatch].self, forKey: .matches) ?? [:]
        unmatched = try c.decodeIfPresent(Set<Int64>.self, forKey: .unmatched) ?? []
        unmatchedAt = try c.decodeIfPresent([Int64: Date].self, forKey: .unmatchedAt) ?? [:]
        pending = try c.decodeIfPresent([PendingTransfer].self, forKey: .pending) ?? []
        recentSearches = try c.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
        lastPlayed = try c.decodeIfPresent(PlayedTitle.self, forKey: .lastPlayed)
        folderIDs = try c.decodeIfPresent([String: Int64].self, forKey: .folderIDs) ?? [:]
        myList = try c.decodeIfPresent([SavedTitle].self, forKey: .myList) ?? []
        finished = try c.decodeIfPresent([FinishedFile].self, forKey: .finished) ?? []
        downloads = try c.decodeIfPresent([DownloadRecord].self, forKey: .downloads) ?? []
        subtitleChoices = try c.decodeIfPresent([Int64: SubtitleChoice].self, forKey: .subtitleChoices) ?? [:]
        imdbWatchlist = try c.decodeIfPresent([SavedTitle].self, forKey: .imdbWatchlist) ?? []
        imdbMatches = try c.decodeIfPresent([String: SavedTitle].self, forKey: .imdbMatches) ?? [:]
        followedShows = try c.decodeIfPresent([SavedTitle].self, forKey: .followedShows) ?? []
    }
}

public actor LocalStore {
    private let fileURL: URL?
    private var state: LocalState
    /// Apple TV keeps files in Caches, which tvOS may clear when storage runs low; My List (which exists nowhere
    /// else) is also kept here and restored if the file is gone.
    private nonisolated(unsafe) let backup: UserDefaults?
    static let myListBackupKey = "amdb.myList.backup"

    /// - Parameter backupSuite: a UserDefaults suite that also keeps My List (used on Apple TV).
    public init(fileURL: URL?, backupSuite: String? = nil) {
        self.fileURL = fileURL
        let backup = backupSuite.flatMap(UserDefaults.init(suiteName:))
        self.backup = backup
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LocalState.self, from: data) {
            state = decoded
        } else {
            state = LocalState()
            if let data = backup?.data(forKey: Self.myListBackupKey),
               let saved = try? JSONDecoder().decode([SavedTitle].self, from: data) {
                state.myList = saved
            }
        }
    }

    public static func defaultURL() -> URL {
        StorageLocation.directory.appending(path: "state.json")
    }

    public var snapshot: LocalState { state }

    public func update(_ body: @Sendable (inout LocalState) -> Void) {
        body(&state)
        persist()
    }

    public func addRecentSearch(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        state.recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        state.recentSearches.insert(query, at: 0)
        state.recentSearches = Array(state.recentSearches.prefix(10))
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: fileURL, options: .atomic) }
        if let backup, let list = try? JSONEncoder().encode(state.myList) { backup.set(list, forKey: Self.myListBackupKey) }
    }
}
