import AMDBCore
import Foundation
import Observation

public struct LibraryEntry: Identifiable, Sendable, Hashable, Codable {
    public let file: PutioFile
    public var match: LibraryMatch?
    public let folderName: String?

    public init(file: PutioFile, match: LibraryMatch?, folderName: String?) {
        self.file = file; self.match = match; self.folderName = folderName
    }

    public var id: Int64 { file.id }
    public var startFrom: Int { file.startFrom ?? 0 }
    public var displayTitle: String { match?.title ?? (file.name as NSString).deletingPathExtension }
}

/// The put.io library as last seen, kept on the device so launch shows it instantly.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var entries: [LibraryEntry]
    public var updatedAt: Date
    /// Resume positions saved locally since that fetch (put.io has them too, but the cache may predate them).
    public var progress: [Int64: Int]?
    /// Every folder seen in that fetch (for organizing without re-listing put.io).
    public var folders: [PutioFile]?

    public init(entries: [LibraryEntry], updatedAt: Date, progress: [Int64: Int]? = nil, folders: [PutioFile]? = nil) {
        self.entries = entries; self.updatedAt = updatedAt; self.progress = progress; self.folders = folders
    }
}

/// On-disk library snapshot (nil URL = memory only, for tests and demo).
public actor LibraryCache {
    private let fileURL: URL?
    private var memory: LibrarySnapshot?

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "AMDB/library.json")
    }

    public func load() -> LibrarySnapshot? {
        if let memory { return memory }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        memory = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        return memory
    }

    public func save(_ snapshot: LibrarySnapshot) {
        memory = snapshot
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        memory = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }
}

/// What a refresh found compared with the library before it.
public struct LibraryChange: Sendable, Equatable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
    public var isEmpty: Bool { added == 0 && removed == 0 }
}

@Observable @MainActor
public final class LibraryIndex {
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: AppError?
    /// When the library was last fetched from put.io (from the cache on launch).
    public private(set) var lastUpdated: Date?
    /// put.io folders as of the last walk.
    public private(set) var folderTree = FolderTree(folders: [])
    /// Called after each successful refresh with what changed.
    @ObservationIgnored public var onUpdated: ((LibraryChange) -> Void)?

    private let store: LocalStore
    private let cache: LibraryCache
    private let maxFolders: Int
    private let parallelism: Int
    private var putio: (any PutioService)?
    private var matcher: LibraryMatcher?
    private var progressOverrides: [Int64: Int] = [:]
    /// Order in which files were watched this session (higher = more recent); a counter, so ties can't happen.
    private var touchedOrder: [Int64: Int] = [:]
    private var touchCount = 0

    public init(store: LocalStore, cache: LibraryCache = LibraryCache(fileURL: nil), maxFolders: Int = 300, parallelism: Int = 6) {
        self.store = store
        self.cache = cache
        self.maxFolders = maxFolders
        self.parallelism = max(parallelism, 1)
    }

    public func configure(putio: (any PutioService)?, catalog: (any CatalogService)?) {
        let signedOut = self.putio != nil && putio == nil
        self.putio = putio
        matcher = catalog.map { LibraryMatcher(catalog: $0) }
        if putio == nil {
            entries = []
            lastUpdated = nil
            // Signing out forgets the cached library so another account never sees it.
            if signedOut { Task { [cache] in await cache.clear() } }
        }
    }

    /// Shows the library saved last time, instantly, before any network request.
    public func loadCached() async {
        guard entries.isEmpty, let snapshot = await cache.load() else { return }
        entries = Self.sorted(snapshot.entries)
        lastUpdated = snapshot.updatedAt
        folderTree = FolderTree(folders: snapshot.folders ?? [])
        for (id, seconds) in snapshot.progress ?? [:] where progressOverrides[id] == nil { progressOverrides[id] = seconds }
    }

    /// Whether the library is older than `maxAge` (or was never fetched).
    public func isStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= maxAge
    }

    public func refresh() async {
        guard let putio, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let before = Set(entries.map(\.id))
        do {
            var folders: [PutioFile] = []
            let found = try await Self.walk(putio, maxFolders: maxFolders, parallelism: parallelism) { folders.append($0) }
            folderTree = FolderTree(folders: folders)
            let state = await store.snapshot
            var result = found.map { LibraryEntry(file: $0.file, match: state.matches[$0.file.id], folderName: $0.folder) }
            entries = Self.sorted(result)
            lastError = nil
            guard let matcher else { return }
            for index in result.indices where result[index].match == nil && !state.unmatched.contains(result[index].id) {
                let entry = result[index]
                let match = await Self.match(entry, matcher)
                result[index].match = match
                let id = entry.id
                await store.update { state in
                    if let match { state.matches[id] = match } else { state.unmatched.insert(id) }
                }
                if index % 10 == 9 { entries = Self.sorted(result) }
            }
            entries = Self.sorted(result)
            let now = Date()
            lastUpdated = now
            // put.io's fresh positions win over ones restored from the cache; this session's still win over put.io.
            progressOverrides = progressOverrides.filter { touchedOrder[$0.key] != nil }
            await persist()
            let after = Set(entries.map(\.id))
            onUpdated?(LibraryChange(added: after.subtracting(before).count, removed: before.subtracting(after).count))
        } catch is CancellationError {
            return
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .transport(error.localizedDescription)
        }
    }

    /// In-progress files, most recently watched first, one per title: a movie with several versions,
    /// or a show with several started episodes, appears once at whichever was watched last.
    public var continueWatching: [LibraryEntry] {
        let started = entries.filter { resumeSeconds(for: $0) >= 30 }.sorted { a, b in
            let ta = touchedOrder[a.id], tb = touchedOrder[b.id]
            if ta != nil || tb != nil { return (ta ?? -1) > (tb ?? -1) }
            return (a.file.updatedAt ?? "") > (b.file.updatedAt ?? "")
        }
        var seen: Set<String> = []
        return started.filter { entry in
            seen.insert(entry.match.map { "\($0.mediaType.rawValue)-\($0.tmdbID)" } ?? "file-\(entry.id)").inserted
        }
    }

    public var recentlyAdded: [LibraryEntry] { Array(entries.prefix(20)) }

    public func matching(tmdbID: Int, season: Int? = nil, episode: Int? = nil) -> [LibraryEntry] {
        entries.filter {
            $0.match?.tmdbID == tmdbID
                && (season == nil || $0.match?.season == season)
                && (episode == nil || $0.match?.episode == episode)
        }
    }

    public func resumeSeconds(for entry: LibraryEntry) -> Int { progressOverrides[entry.id] ?? entry.startFrom }

    public func noteProgress(fileID: Int64, seconds: Int) {
        progressOverrides[fileID] = seconds
        touchCount += 1
        touchedOrder[fileID] = touchCount
        Task { await persist() }
    }

    /// Deletes files from put.io and forgets them locally.
    public func delete(_ doomed: [LibraryEntry]) async throws {
        guard let putio, !doomed.isEmpty else { return }
        let ids = doomed.map(\.id)
        try await putio.deleteFiles(ids: ids)
        entries.removeAll { ids.contains($0.id) }
        await store.update { state in
            state.finished.removeAll { ids.contains($0.fileID) }
            for id in ids { state.matches[id] = nil }
        }
        await persist()
    }

    public func record(file: PutioFile, match: LibraryMatch) async {
        let id = file.id
        await store.update { state in
            state.matches[id] = match
            state.unmatched.remove(id)
        }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].match = match
        } else {
            entries.insert(LibraryEntry(file: file, match: match, folderName: nil), at: 0)
        }
        await persist()
    }

    struct FoundVideo: Sendable { let file: PutioFile; let folder: String? }

    /// Breadth-first walk of the put.io tree, listing up to `parallelism` folders at a time.
    static func walk(_ putio: any PutioService, maxFolders: Int, parallelism: Int = 6,
                     onFolder: (PutioFile) -> Void = { _ in }) async throws -> [FoundVideo] {
        var queue: [(id: Int64, name: String?)] = [(0, nil)]
        var visited = 0
        var videos: [FoundVideo] = []
        while !queue.isEmpty, visited < maxFolders {
            try Task.checkCancellation()
            let batch = Array(queue.prefix(min(parallelism, maxFolders - visited)))
            queue.removeFirst(batch.count)
            visited += batch.count
            let listed = try await withThrowingTaskGroup(of: (Int, [PutioFile]).self) { group in
                for (index, folder) in batch.enumerated() {
                    group.addTask { (index, try await putio.listFiles(parentID: folder.id).files) }
                }
                var results: [(Int, [PutioFile])] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            for (index, files) in listed {
                for file in files {
                    if file.isFolder {
                        queue.append((file.id, file.name))
                        onFolder(file)
                    } else if file.isVideo, !isSample(file) {
                        videos.append(FoundVideo(file: file, folder: batch[index].name))
                    }
                }
            }
        }
        return videos
    }

    private func persist() async {
        guard let lastUpdated else { return }
        await cache.save(LibrarySnapshot(entries: entries, updatedAt: lastUpdated, progress: progressOverrides,
                                         folders: Array(folderTree.folders.values)))
    }

    static func isSample(_ file: PutioFile) -> Bool {
        file.name.lowercased().contains("sample") && (file.size ?? 0) < 300_000_000
    }

    static func match(_ entry: LibraryEntry, _ matcher: LibraryMatcher) async -> LibraryMatch? {
        if let match = try? await matcher.match(fileName: entry.file.name) { return match }
        guard let folder = entry.folderName, let match = try? await matcher.match(fileName: folder) else { return nil }
        // A folder like "Show S02" names the show; keep any episode number the file name carries.
        let parsed = ReleaseNameParser.parse(entry.file.name)
        return LibraryMatch(tmdbID: match.tmdbID, mediaType: match.mediaType,
                            season: parsed.season ?? match.season, episode: parsed.episode ?? match.episode,
                            confidence: match.confidence * 0.9, title: match.title, year: match.year,
                            posterPath: match.posterPath, backdropPath: match.backdropPath)
    }

    static func sorted(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.sorted { ($0.file.createdAt ?? "") > ($1.file.createdAt ?? "") }
    }
}
