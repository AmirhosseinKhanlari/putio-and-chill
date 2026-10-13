import AMDBCore
import Foundation
import Observation

public struct LibraryEntry: Identifiable, Sendable, Hashable {
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

@Observable @MainActor
public final class LibraryIndex {
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var isRefreshing = false
    public private(set) var lastError: AppError?

    private let store: LocalStore
    private let maxFolders: Int
    private var putio: (any PutioService)?
    private var matcher: LibraryMatcher?
    private var progressOverrides: [Int64: Int] = [:]
    private var touchedAt: [Int64: Date] = [:]

    public init(store: LocalStore, maxFolders: Int = 300) {
        self.store = store
        self.maxFolders = maxFolders
    }

    public func configure(putio: (any PutioService)?, catalog: (any CatalogService)?) {
        self.putio = putio
        matcher = catalog.map { LibraryMatcher(catalog: $0) }
        if putio == nil { entries = [] }
    }

    public func refresh() async {
        guard let putio, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let found = try await Self.walk(putio, maxFolders: maxFolders)
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
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .transport(error.localizedDescription)
        }
    }

    public var continueWatching: [LibraryEntry] {
        entries.filter { resumeSeconds(for: $0) >= 30 }.sorted { a, b in
            let ta = touchedAt[a.id], tb = touchedAt[b.id]
            if ta != nil || tb != nil { return (ta ?? .distantPast) > (tb ?? .distantPast) }
            return (a.file.updatedAt ?? "") > (b.file.updatedAt ?? "")
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
        touchedAt[fileID] = Date()
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
    }

    struct FoundVideo: Sendable { let file: PutioFile; let folder: String? }

    static func walk(_ putio: any PutioService, maxFolders: Int) async throws -> [FoundVideo] {
        var queue: [(id: Int64, name: String?)] = [(0, nil)]
        var visited = 0
        var videos: [FoundVideo] = []
        while !queue.isEmpty, visited < maxFolders {
            let folder = queue.removeFirst()
            visited += 1
            for file in try await putio.listFiles(parentID: folder.id).files {
                if file.isFolder {
                    queue.append((file.id, file.name))
                } else if file.isVideo, !isSample(file) {
                    videos.append(FoundVideo(file: file, folder: folder.name))
                }
            }
        }
        return videos
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
