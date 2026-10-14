import AMDBCore
import Foundation

public enum PlaybackResolver {
    /// The largest video inside `fileID` (the file itself when it is a video), searching up to three folder levels.
    public static func playableFile(_ fileID: Int64, putio: any PutioService) async throws -> PutioFile? {
        let root = try await putio.file(id: fileID)
        if root.isVideo { return root }
        guard root.isFolder else { return nil }
        var best: PutioFile?
        var level = [root.id]
        for _ in 0..<3 where !level.isEmpty {
            var next: [Int64] = []
            for folderID in level {
                for file in try await putio.listFiles(parentID: folderID).files {
                    if file.isFolder {
                        next.append(file.id)
                    } else if file.isVideo, (file.size ?? 0) > (best?.size ?? -1) {
                        best = file
                    }
                }
            }
            level = next
        }
        return best
    }

    /// Every video inside `fileID` (three folder levels down; samples and subtitle folders skipped), in name order.
    public static func videos(in fileID: Int64, putio: any PutioService) async throws -> [PutioFile] {
        let root = try await putio.file(id: fileID)
        if root.isVideo { return [root] }
        guard root.isFolder else { return [] }
        var found: [PutioFile] = []
        var level = [root.id]
        for _ in 0..<3 where !level.isEmpty {
            var next: [Int64] = []
            for folderID in level {
                for file in try await putio.listFiles(parentID: folderID).files {
                    if file.isFolder {
                        if !LibraryIndex.isSkippedFolder(file.name) { next.append(file.id) }
                    } else if file.isVideo, !LibraryIndex.isSample(file) {
                        found.append(file)
                    }
                }
            }
            level = next
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum FolderResolver {
    /// Finds or creates `path` (e.g. ["AMDB", "Movies"]) under `root` (the put.io root by default) and caches its id.
    public static func folderID(path: [String], under root: Int64 = 0, putio: any PutioService, store: LocalStore) async throws -> Int64 {
        guard !path.isEmpty else { return root }
        let key = cacheKey(path, root)
        if let cached = await store.snapshot.folderIDs[key] { return cached }
        var parent = root
        for name in path {
            let children = try await putio.listFiles(parentID: parent).files
            if let existing = children.first(where: { $0.isFolder && $0.name == name }) {
                parent = existing.id
            } else {
                parent = try await putio.createFolder(name: name, parentID: parent).id
            }
        }
        let id = parent
        await store.update { $0.folderIDs[key] = id }
        return id
    }

    /// Like `folderID`, but never creates anything: nil when part of the path doesn't exist.
    public static func existingID(path: [String], under root: Int64 = 0, putio: any PutioService, store: LocalStore) async throws -> Int64? {
        guard !path.isEmpty else { return root }
        if let cached = await store.snapshot.folderIDs[cacheKey(path, root)] { return cached }
        var parent = root
        for name in path {
            guard let existing = try await putio.listFiles(parentID: parent).files.first(where: { $0.isFolder && $0.name == name })
            else { return nil }
            parent = existing.id
        }
        return parent
    }

    public static func forget(path: [String], under root: Int64 = 0, store: LocalStore) async {
        let key = cacheKey(path, root)
        await store.update { $0.folderIDs[key] = nil }
    }

    /// Drops every cached folder id (after put.io reports a folder is gone).
    public static func forgetAll(store: LocalStore) async {
        await store.update { $0.folderIDs = [:] }
    }

    /// Old cache entries (root 0) keep their "AMDB/Movies" keys.
    private static func cacheKey(_ path: [String], _ root: Int64) -> String {
        root == 0 ? path.joined(separator: "/") : "\(root):" + path.joined(separator: "/")
    }
}

/// Where things are saved in put.io: a base folder for movies and one for shows (picked in Settings, or AMDB/…),
/// then a folder per show and, optionally, per season.
public struct FolderLayout: Sendable, Hashable {
    public var movies: PutioFolderRef?
    public var tv: PutioFolderRef?
    public var seasonFolders: Bool

    public static let defaultMoviesPath = ["AMDB", "Movies"]
    public static let defaultTVPath = ["AMDB", "TV"]
    public static let standard = FolderLayout(movies: nil, tv: nil, seasonFolders: true)

    public init(movies: PutioFolderRef?, tv: PutioFolderRef?, seasonFolders: Bool) {
        self.movies = movies; self.tv = tv; self.seasonFolders = seasonFolders
    }

    public init(settings: AppSettings) {
        self.init(movies: settings.moviesFolder, tv: settings.tvFolder, seasonFolders: settings.seasonFolders)
    }

    /// Folders below the base: nothing for movies; the show, then "Season N" for shows.
    public func subpath(kind: MediaKind, title: String, season: Int?) -> [String] {
        guard kind == .tv else { return [] }
        let show = Self.folderName(title)
        if seasonFolders, let season { return [show, "Season \(season)"] }
        return [show]
    }

    /// Human-readable destination, e.g. "AMDB/TV/Severance/Season 2".
    public func displayPath(kind: MediaKind, title: String, season: Int?) -> String {
        let base = kind == .tv ? (tv?.path ?? Self.defaultTVPath.joined(separator: "/"))
                               : (movies?.path ?? Self.defaultMoviesPath.joined(separator: "/"))
        return ([base] + subpath(kind: kind, title: title, season: season)).joined(separator: "/")
    }

    /// The destination folder id, creating missing folders.
    public func destinationID(kind: MediaKind, title: String, season: Int?, putio: any PutioService, store: LocalStore) async throws -> Int64 {
        let (root, basePath) = base(kind)
        return try await FolderResolver.folderID(path: basePath + subpath(kind: kind, title: title, season: season), under: root,
                                                 putio: putio, store: store)
    }

    /// The destination folder id if it already exists (from `tree` when known, else asking put.io).
    public func existingDestinationID(kind: MediaKind, title: String, season: Int?, putio: any PutioService,
                                      store: LocalStore, tree: FolderTree? = nil) async throws -> Int64? {
        let (root, basePath) = base(kind)
        let path = basePath + subpath(kind: kind, title: title, season: season)
        if let tree, !tree.isEmpty { return tree.resolve(path, under: root) }
        return try await FolderResolver.existingID(path: path, under: root, putio: putio, store: store)
    }

    /// The base folder's id if it exists.
    func existingBaseID(_ kind: MediaKind, putio: any PutioService, store: LocalStore, tree: FolderTree?) async throws -> Int64? {
        let (root, basePath) = base(kind)
        if let tree, !tree.isEmpty { return tree.resolve(basePath, under: root) }
        return try await FolderResolver.existingID(path: basePath, under: root, putio: putio, store: store)
    }

    private func base(_ kind: MediaKind) -> (root: Int64, path: [String]) {
        if kind == .tv { return tv.map { ($0.id, []) } ?? (0, Self.defaultTVPath) }
        return movies.map { ($0.id, []) } ?? (0, Self.defaultMoviesPath)
    }

    /// put.io folder names can't contain "/".
    static func folderName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

/// The put.io folder structure as of the last library walk: answers "what's inside / above this folder" without requests.
public struct FolderTree: Sendable, Equatable {
    public private(set) var folders: [Int64: PutioFile]
    private var childrenByParent: [Int64: [PutioFile]]

    public init(folders: [PutioFile]) {
        self.folders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        childrenByParent = Dictionary(grouping: folders) { $0.parentId ?? 0 }
    }

    public var isEmpty: Bool { folders.isEmpty }

    public func child(named name: String, in parent: Int64) -> PutioFile? {
        childrenByParent[parent]?.first { $0.name == name }
    }

    /// Follows `path` from `root`; nil when a step is missing.
    public func resolve(_ path: [String], under root: Int64) -> Int64? {
        var current = root
        for name in path {
            guard let next = child(named: name, in: current) else { return nil }
            current = next.id
        }
        return current
    }
}
