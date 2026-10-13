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

public struct LocalState: Codable, Sendable, Equatable {
    public var matches: [Int64: LibraryMatch] = [:]
    public var unmatched: Set<Int64> = []
    public var pending: [PendingTransfer] = []
    public var recentSearches: [String] = []
    public var lastPlayed: PlayedTitle?
    public var folderIDs: [String: Int64] = [:]
    public var myList: [SavedTitle] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
        case matches, unmatched, pending, recentSearches, lastPlayed, folderIDs, myList
    }

    /// Every field is optional on disk, so files written by older versions keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matches = try c.decodeIfPresent([Int64: LibraryMatch].self, forKey: .matches) ?? [:]
        unmatched = try c.decodeIfPresent(Set<Int64>.self, forKey: .unmatched) ?? []
        pending = try c.decodeIfPresent([PendingTransfer].self, forKey: .pending) ?? []
        recentSearches = try c.decodeIfPresent([String].self, forKey: .recentSearches) ?? []
        lastPlayed = try c.decodeIfPresent(PlayedTitle.self, forKey: .lastPlayed)
        folderIDs = try c.decodeIfPresent([String: Int64].self, forKey: .folderIDs) ?? [:]
        myList = try c.decodeIfPresent([SavedTitle].self, forKey: .myList) ?? []
    }
}

public actor LocalStore {
    private let fileURL: URL?
    private var state: LocalState

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LocalState.self, from: data) {
            state = decoded
        } else {
            state = LocalState()
        }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AMDB/state.json")
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
    }
}
