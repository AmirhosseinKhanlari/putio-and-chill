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

/// The folders Putio & Chill saves into by default: "Movies" and "TV Series" at the top of put.io. Builds before
/// these used AMDB/Movies and AMDB/TV; `OldFolderMerge` moves those into these once.
public enum DefaultFolders {
    public static let movies = "Movies"
    public static let tv = "TV Series"
    /// Where older builds saved: AMDB/Movies and AMDB/TV.
    public static let oldRoot = "AMDB"
    public static let oldMovies = "Movies"
    public static let oldTV = "TV"

    /// Folder names are compared ignoring case and surrounding spaces ("tv series" is "TV Series").
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func sameName(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// The folder in `files` called `name`: the exact spelling first, else one that differs only in case or spaces.
    public static func folder(named name: String, in files: [PutioFile]) -> PutioFile? {
        files.first { $0.isFolder && $0.name == name } ?? files.first { $0.isFolder && sameName($0.name, name) }
    }

    /// Whether a folder picked in Settings is one of the old AMDB/Movies or AMDB/TV folders (by its path, or by an id
    /// known to be one of them). Those picks go back to the defaults.
    public static func isOldFolder(_ ref: PutioFolderRef, oldIDs: Set<Int64> = []) -> Bool {
        if oldIDs.contains(ref.id) { return true }
        let parts = ref.path.split(separator: "/").map { key(String($0)) }.filter { !$0.isEmpty }
        return parts.count == 2 && parts[0] == key(oldRoot) && (parts[1] == key(oldMovies) || parts[1] == key(oldTV))
    }
}

public enum FolderResolver {
    /// Finds or creates `path` (e.g. ["TV Series", "Severance"]) under `root` (the put.io root by default) and caches
    /// its id. Existing folders are found ignoring case ("tv series" counts as "TV Series").
    public static func folderID(path: [String], under root: Int64 = 0, putio: any PutioService, store: LocalStore) async throws -> Int64 {
        guard !path.isEmpty else { return root }
        let key = cacheKey(path, root)
        if let cached = await store.snapshot.folderIDs[key] { return cached }
        var parent = root
        for name in path {
            let children = try await putio.listFiles(parentID: parent).files
            if let existing = DefaultFolders.folder(named: name, in: children) {
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
            guard let existing = DefaultFolders.folder(named: name, in: try await putio.listFiles(parentID: parent).files)
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

    /// Entries under the root have plain keys ("Movies", "TV Series/Severance"); others start with the root's id.
    private static func cacheKey(_ path: [String], _ root: Int64) -> String {
        root == 0 ? path.joined(separator: "/") : "\(root):" + path.joined(separator: "/")
    }
}

/// Where things are saved in put.io: a base folder for movies and one for shows (picked in Settings, else Movies and
/// TV Series at the top of put.io), then a folder per show and, optionally, per season.
public struct FolderLayout: Sendable, Hashable {
    public var movies: PutioFolderRef?
    public var tv: PutioFolderRef?
    public var seasonFolders: Bool

    public static let defaultMoviesPath = [DefaultFolders.movies]
    public static let defaultTVPath = [DefaultFolders.tv]
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

    /// Human-readable destination, e.g. "TV Series/Severance/Season 2".
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

    /// The exact spelling first, else a folder whose name differs only in case or spaces (as `FolderResolver` finds it).
    public func child(named name: String, in parent: Int64) -> PutioFile? {
        DefaultFolders.folder(named: name, in: childrenByParent[parent] ?? [])
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
