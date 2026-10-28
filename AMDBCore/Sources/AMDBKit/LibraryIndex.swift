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

    /// The movie or show this file is (for its title page); nil when it isn't matched.
    public var titleItem: CatalogItem? {
        match.map { CatalogItem(tmdbID: $0.tmdbID, mediaType: $0.mediaType, title: $0.title, posterPath: $0.posterPath,
                                backdropPath: $0.backdropPath, year: $0.year) }
    }
}

/// The put.io library as last seen, kept on the device so launch shows it instantly.
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var entries: [LibraryEntry]
    public var updatedAt: Date
    /// Resume positions saved by older builds (read once into `positions`, no longer written).
    public var progress: [Int64: Int]?
    /// Every folder seen in that fetch (for organizing without re-listing put.io).
    public var folders: [PutioFile]?
    /// Video lengths in seconds, learned while playing (put.io only keeps the position). Absent in older caches.
    public var durations: [Int64: Int]?
    /// When each file was last watched, saved by older builds (read once into `positions`, no longer written).
    public var watched: [Int64: Date]?
    /// `LibraryScope.signature` of the walk that found these entries (absent in older caches, which read all of put.io).
    public var scope: String?
    /// Resume positions with when they were true and where they came from (this device, put.io, the other devices).
    public var positions: [Int64: WatchProgress]?
    /// Cards removed from Continue Watching (`LibraryIndex.removeFromContinueWatching`). Absent in older caches.
    public var hiddenCards: [Int64: Int]?

    public init(entries: [LibraryEntry], updatedAt: Date, progress: [Int64: Int]? = nil, folders: [PutioFile]? = nil,
                durations: [Int64: Int]? = nil, watched: [Int64: Date]? = nil, scope: String? = nil,
                positions: [Int64: WatchProgress]? = nil, hiddenCards: [Int64: Int]? = nil) {
        self.entries = entries; self.updatedAt = updatedAt; self.progress = progress; self.folders = folders
        self.durations = durations; self.watched = watched; self.scope = scope; self.positions = positions
        self.hiddenCards = hiddenCards
    }

    /// Positions, including those an older build saved (as already sent to put.io: put.io's newer value may replace them).
    var allPositions: [Int64: WatchProgress] {
        var all = positions ?? [:]
        for (id, seconds) in progress ?? [:] where all[id] == nil {
            let watchedAt = watched?[id]
            all[id] = WatchProgress(seconds: seconds, at: watchedAt ?? updatedAt, source: .device, watchedAt: watchedAt)
        }
        return all
    }
}

/// On-disk library snapshot (nil URL = memory only, for tests and demo).
public actor LibraryCache {
    private let fileURL: URL?
    private var memory: LibrarySnapshot?

    public init(fileURL: URL?) { self.fileURL = fileURL }

    public static func defaultURL() -> URL {
        StorageLocation.directory.appending(path: "library.json")
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
    /// The first update after what the library reads changed (`LibraryScope`): files that left are out of scope,
    /// not deleted, so this isn't news to announce.
    public let rescoped: Bool

    public init(added: Int, removed: Int, rescoped: Bool = false) {
        self.added = added; self.removed = removed; self.rescoped = rescoped
    }
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
    /// What the library reads in put.io (from Settings). A change makes the library due for an update.
    @ObservationIgnored public var scope = LibraryScope.standard {
        didSet { if oldValue.signature != scope.signature, lastUpdated != nil { needsRescan = true } }
    }
    /// The entries on screen came from a different scope (an older build, or a folder picked since): read put.io again
    /// even when the library isn't otherwise due.
    public private(set) var needsRescan = false
    /// The scope the entries on screen were read with.
    private var entriesScope: String?

    let store: LocalStore
    private let cache: LibraryCache
    private let maxFolders: Int
    private let parallelism: Int
    private var putio: (any PutioService)?
    private(set) var matcher: LibraryMatcher?
    /// Fix Match choices (a copy of what `LocalState` keeps), applied before automatic matching.
    public internal(set) var overrides = MatchOverrides()
    /// Files found on put.io that are still being matched to TMDB (not shown yet).
    public private(set) var pendingMatches = 0
    /// Four lookups at a time keeps well under TMDB's rate limit (each file can take two searches).
    private let matchParallelism = 4
    @ObservationIgnored private var currentRefresh: Task<Void, Never>?
    /// Resume positions, newest wins (`WatchProgress.merged`); kept in the cache and never dropped by an update.
    var positions: [Int64: WatchProgress] = [:]
    /// Video lengths (seconds) seen by the player, so cards can show how much is left.
    var durations: [Int64: Int] = [:]
    /// Order in which files were watched this session (higher = more recent); a counter, so ties can't happen.
    private var touchedOrder: [Int64: Int] = [:]
    private var touchCount = 0
    /// Played files the library didn't have (from Files, a transfer that just finished, another device): shown at once,
    /// and kept through an update that was already walking put.io when they were played. Each update starts this over.
    private var playedOutside: [Int64: LibraryEntry] = [:]
    /// Files put.io says no longer exist (asked for their position): never brought back from another device's list.
    var goneFiles: Set<Int64> = []
    /// What TMDB said comes after each show's watched episode (`ContinueWatching`); kept for this session.
    var upNextFound: [EpisodeKey: UpNextFound] = [:]
    /// Files whose Continue Watching card was removed, with what the card showed then (`ContinueWatching.swift`).
    var hiddenCards: [Int64: Int] = [:]
    /// put.io, for reading and sending positions (`LibraryIndex+Positions`).
    var putioService: (any PutioService)? { putio }

    public init(store: LocalStore, cache: LibraryCache = LibraryCache(fileURL: nil), maxFolders: Int = 2000, parallelism: Int = 6) {
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
            playedOutside = [:]
            positions = [:]
            upNextFound = [:]
            touchedOrder = [:]
            lastUpdated = nil
            entriesScope = nil
            needsRescan = false
            // Signing out forgets the cached library so another account never sees it.
            if signedOut { Task { [cache] in await cache.clear() } }
        }
    }

    /// Shows the library saved last time, instantly, before any network request.
    public func loadCached() async {
        overrides = await store.snapshot.matchOverrides
        guard entries.isEmpty, let snapshot = await cache.load() else { return }
        entries = Self.sorted(snapshot.entries.map { entry in
            var entry = entry
            if let fixed = EpisodeNumbering.repaired(entry.match, fileName: entry.file.name) { entry.match = fixed }
            return entry
        })
        lastUpdated = snapshot.updatedAt
        entriesScope = snapshot.scope
        needsRescan = snapshot.scope != scope.signature
        folderTree = FolderTree(folders: snapshot.folders ?? [])
        // Anything noted since launch is newer than the cache.
        for (id, saved) in snapshot.allPositions { positions[id] = WatchProgress.merged(saved, positions[id] ?? saved) }
        for (id, seconds) in snapshot.durations ?? [:] where durations[id] == nil { durations[id] = seconds }
        for (id, mark) in snapshot.hiddenCards ?? [:] where hiddenCards[id] == nil { hiddenCards[id] = mark }
    }

    /// Whether the library is older than `maxAge` (or was never fetched).
    public func isStale(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastUpdated, !needsRescan else { return true }
        return now.timeIntervalSince(lastUpdated) >= maxAge
    }

    /// How long a file with no TMDB match waits before it's looked up again.
    public static let unmatchedRetry: TimeInterval = 3 * 86_400

    /// Re-reads put.io and matches new files to TMDB. `retryUnmatched` (pull to refresh, Update Now) also looks up
    /// again every file that had no match. `afterChanges`: put.io just changed, so an update that was already running
    /// (and may have read the old state) doesn't count.
    public func refresh(retryUnmatched: Bool = false, afterChanges: Bool = false, now: Date = Date()) async {
        // An update is already running (e.g. the one at launch): wait for it. If this one was asked for by the user
        // (pull to refresh, Update Now) or follows changes, run again afterwards rather than doing nothing.
        if let running = currentRefresh {
            await running.value
            guard retryUnmatched || afterChanges else { return }
            // Someone else already started a newer one meanwhile: that one will do.
            if let another = currentRefresh, another != running { await another.value; return }
        }
        let task = Task { await self.performRefresh(retryUnmatched: retryUnmatched, now: now) }
        currentRefresh = task
        await task.value
        if currentRefresh == task { currentRefresh = nil }
    }

    private func performRefresh(retryUnmatched: Bool, now: Date) async {
        guard let putio else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // put.io is the truth for files played before this walk; ones played during it are kept (see withPlayed).
        playedOutside = [:]
        let before = Set(entries.map(\.id))
        let scope = scope
        let rescoped = needsRescan
        // put.io's positions in the list are as of when the walk began (a save during it is newer).
        let walkStarted = Date()
        let updatedBefore = lastUpdated != nil
        do {
            var folders: [PutioFile] = []
            let found = try await Self.walk(putio, scope: scope, maxFolders: maxFolders, parallelism: parallelism) { folders.append($0) }
            folderTree = FolderTree(folders: folders)
            entriesScope = scope.signature
            if self.scope.signature == scope.signature { needsRescan = false }
            notePutioList(found.map(\.file), readAt: walkStarted, firstRead: !updatedBefore)
            let state = await store.snapshot
            var result = found.map { LibraryEntry(file: $0.file, match: state.matches[$0.file.id], folderName: $0.folder) }
            // Earlier builds saved one file of each finished season pack as "season N" with no episode: complete
            // those from the file name (nothing else saved about them changes).
            var repaired: [Int64: LibraryMatch] = [:]
            for index in result.indices {
                if let fixed = EpisodeNumbering.repaired(result[index].match, fileName: result[index].file.name) {
                    result[index].match = fixed
                    repaired[result[index].id] = fixed
                }
            }
            if !repaired.isEmpty {
                let fixes = repaired
                await store.update { state in for (id, match) in fixes { state.matches[id] = match } }
            }
            // Fix Match choices come first: those files are never looked up.
            overrides = state.matchOverrides
            for index in result.indices {
                if let chosen = override(for: result[index].file) {
                    result[index].match = chosen.match(fileName: result[index].file.name)
                }
            }
            lastError = nil
            guard let matcher else {
                entries = withPlayed(result)
                return
            }
            // A file shows once it's matched (or known not to match), never as a raw file name while it waits.
            // "No match" is trusted for three days (and never when it has no date: older builds also recorded
            // network errors as no match).
            func knownMiss(_ id: Int64) -> Bool {
                guard !retryUnmatched, state.unmatched.contains(id), let at = state.unmatchedAt[id] else { return false }
                return now.timeIntervalSince(at) < Self.unmatchedRetry
            }
            var settled = result.map { $0.match != nil || knownMiss($0.id) }
            let pending = result.indices.filter { !settled[$0] }
            pendingMatches = pending.count
            entries = withPlayed(result.indices.filter { settled[$0] }.map { result[$0] })
            await withTaskGroup(of: (Int, MatchOutcome).self) { group in
                var next = 0
                var done = 0
                func add() {
                    let index = pending[next]
                    let entry = result[index]
                    group.addTask { (index, await Self.matchOutcome(entry, matcher)) }
                    next += 1
                }
                while next < min(matchParallelism, pending.count) { add() }
                while let (index, outcome) = await group.next() {
                    let id = result[index].id
                    switch outcome {
                    case let .matched(match):
                        result[index].match = match
                        await store.update { state in
                            state.matches[id] = match
                            state.unmatched.remove(id)
                            state.unmatchedAt[id] = nil
                        }
                    case .noMatch:
                        await store.update { state in
                            state.unmatched.insert(id)
                            state.unmatchedAt[id] = now
                        }
                    case .failed:
                        // TMDB couldn't be reached: not a verdict; the next refresh tries again.
                        break
                    }
                    settled[index] = true
                    done += 1
                    pendingMatches -= 1
                    if done % 6 == 0 { entries = withPlayed(result.indices.filter { settled[$0] }.map { result[$0] }) }
                    if next < pending.count { add() }
                }
            }
            pendingMatches = 0
            entries = withPlayed(result)
            let now = Date()
            lastUpdated = now
            prunePositions(now: now)
            await persist()
            let after = Set(entries.map(\.id))
            onUpdated?(LibraryChange(added: after.subtracting(before).count, removed: before.subtracting(after).count,
                                     rescoped: rescoped))
        } catch is CancellationError {
            return
        } catch let error as AppError {
            lastError = error
        } catch {
            lastError = .transport(error.localizedDescription)
        }
    }

    /// In-progress files of Continue Watching (`continueWatchingCards` without its Up Next cards), most recently
    /// watched first, one per title.
    public var continueWatching: [LibraryEntry] { continueWatchingCards.compactMap(\.resumeEntry) }

    /// Whether `a` was watched more recently than `b`: when it was watched on any device (this one, another through
    /// iCloud, or a change put.io reported), then the order of this session, then put.io's change date.
    func watchedLater(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        let wa = positions[a.id]?.watchedAt, wb = positions[b.id]?.watchedAt
        if wa != wb, wa != nil || wb != nil { return (wa ?? .distantPast) > (wb ?? .distantPast) }
        let ta = touchedOrder[a.id], tb = touchedOrder[b.id]
        if ta != nil || tb != nil { return (ta ?? -1) > (tb ?? -1) }
        return (a.file.updatedAt ?? "") > (b.file.updatedAt ?? "")
    }

    public var recentlyAdded: [LibraryEntry] { Array(entries.prefix(20)) }

    /// Newest movies, or newest shows (each show once, at its newest episode), for the Movies / TV Shows tabs.
    public func recentlyAdded(_ kind: MediaKind, limit: Int = 20) -> [LibraryEntry] {
        var seen: Set<Int> = []
        return Array(entries.filter { entry in
            guard let match = entry.match, match.mediaType == kind else { return false }
            return seen.insert(match.tmdbID).inserted
        }.prefix(limit))
    }

    public func matching(tmdbID: Int, season: Int? = nil, episode: Int? = nil) -> [LibraryEntry] {
        entries.filter {
            $0.match?.tmdbID == tmdbID
                && (season == nil || $0.match?.season == season)
                && (episode == nil || $0.match?.episode == episode)
        }
    }

    /// The newest known position; put.io's list value when nothing else is known.
    public func resumeSeconds(for entry: LibraryEntry) -> Int { positions[entry.id]?.seconds ?? entry.startFrom }

    /// Same, for a file known only by its id.
    public func resumeSeconds(fileID: Int64) -> Int {
        positions[fileID]?.seconds ?? entries.first { $0.id == fileID }?.startFrom ?? 0
    }

    /// The video's length when the player (here or on another device) has seen it.
    public func duration(fileID: Int64) -> Int? { durations[fileID] }

    /// The video's length, as the player found it (saved with the next position).
    public func noteDuration(fileID: Int64, seconds: Int) {
        guard seconds > 0, durations[fileID] != seconds else { return }
        durations[fileID] = seconds
    }

    /// How far into the video (0…1), shown as a bar on its card. Uses the length the player saw, else put.io's,
    /// else `estimatedLength` (TMDB's runtime). nil when it hasn't been started, or the length isn't known.
    public func watchedFraction(for entry: LibraryEntry, estimatedLength: Int? = nil) -> Double? {
        let position = resumeSeconds(for: entry)
        guard position >= 30, let length = durations[entry.id] ?? entry.file.duration ?? estimatedLength, length > 0 else { return nil }
        return min(1, Double(position) / Double(length))
    }

    /// Seconds left to watch, when the length is known (see `watchedFraction`).
    public func remainingSeconds(for entry: LibraryEntry, estimatedLength: Int? = nil) -> Int? {
        let position = resumeSeconds(for: entry)
        guard position >= 30, let length = durations[entry.id] ?? entry.file.duration ?? estimatedLength, length > position else { return nil }
        return length - position
    }

    /// A position saved on this device: the newest there is, waiting to reach put.io (`markSent`). `watched`: it
    /// reached the end (`Watched`; `seconds` is 0 then).
    public func noteProgress(fileID: Int64, seconds: Int, now: Date = Date(), watched: Bool = false) {
        positions[fileID] = WatchProgress.merged(positions[fileID], WatchProgress(seconds: seconds, at: now, source: .device,
                                                                                  watchedAt: now, pending: true,
                                                                                  finishedAt: watched ? now : nil))
        touchCount += 1
        touchedOrder[fileID] = touchCount
        Task { await persist() }
    }

    /// A file being played that the library doesn't have yet (played from Files, a transfer that just finished):
    /// added now so Continue Watching shows it right away, not after the next update. Nothing changes for a file it has.
    public func notePlayed(_ entry: LibraryEntry) {
        goneFiles.remove(entry.id)
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        playedOutside[entry.id] = entry
        entries = Self.sorted(entries + [entry])
    }

    /// A file played elsewhere that put.io no longer has: off the screen now (the next update would drop it anyway).
    func dropPlayedOutside(_ id: Int64) {
        guard playedOutside.removeValue(forKey: id) != nil else { return }
        entries.removeAll { $0.id == id }
    }

    /// What an update found, plus files played while it ran that it didn't find (its walk may have passed their
    /// folder before they were played).
    private func withPlayed(_ found: [LibraryEntry]) -> [LibraryEntry] {
        let ids = Set(found.map(\.id))
        return Self.sorted(found + playedOutside.values.filter { !ids.contains($0.id) })
    }

    /// Deletes files from put.io and forgets them locally.
    public func delete(_ doomed: [LibraryEntry]) async throws {
        guard let putio, !doomed.isEmpty else { return }
        let ids = doomed.map(\.id)
        try await putio.deleteFiles(ids: ids)
        await forget(Set(ids))
    }

    /// Drops files deleted elsewhere (the file manager) right away, with what was saved about them.
    public func forget(_ ids: Set<Int64>) async {
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        for id in ids { playedOutside[id] = nil }
        await store.update { state in
            state.finished.removeAll { ids.contains($0.fileID) }
            for id in ids { state.matches[id] = nil }
        }
        await persist()
    }

    /// Sets (or clears) the match of entries on screen, then saves the library. For Fix Match.
    func setMatches(_ changes: [Int64: LibraryMatch?]) async {
        guard !changes.isEmpty else { return }
        for index in entries.indices {
            if let change = changes[entries[index].id] { entries[index].match = change }
        }
        await persist()
    }

    public func record(file: PutioFile, match: LibraryMatch) async {
        await record([(file, match)])
    }

    /// Several files at once (every episode of a season pack).
    public func record(_ items: [(file: PutioFile, match: LibraryMatch)]) async {
        guard !items.isEmpty else { return }
        await store.update { state in
            for (file, match) in items {
                state.matches[file.id] = match
                state.unmatched.remove(file.id)
                state.unmatchedAt[file.id] = nil
            }
        }
        for (file, match) in items.reversed() {
            if let index = entries.firstIndex(where: { $0.id == file.id }) {
                entries[index].match = match
            } else {
                entries.insert(LibraryEntry(file: file, match: match, folderName: nil), at: 0)
            }
        }
        await persist()
    }

    struct FoundVideo: Sendable { let file: PutioFile; let folder: String? }

    /// Breadth-first walk of what `scope` covers, listing up to `parallelism` folders at a time: the top of put.io
    /// (its loose videos, and the in-scope folders there), everything below those, and the folders picked in Settings.
    /// Every top-level folder is still reported to `onFolder`, so the folder tree can find Movies and TV Series.
    static func walk(_ putio: any PutioService, scope: LibraryScope = .standard, maxFolders: Int, parallelism: Int = 6,
                     onFolder: (PutioFile) -> Void = { _ in }) async throws -> [FoundVideo] {
        struct Pending { let id: Int64; let name: String?; let optional: Bool }
        // A picked folder that no longer exists is skipped rather than failing the whole update.
        var queue = [Pending(id: 0, name: nil, optional: false)]
            + scope.extraRoots.map { Pending(id: $0.id, name: $0.name, optional: true) }
        var queued = Set(queue.map(\.id))
        var seenVideos: Set<Int64> = []
        var visited = 0
        var videos: [FoundVideo] = []
        while !queue.isEmpty, visited < maxFolders {
            try Task.checkCancellation()
            let batch = Array(queue.prefix(min(parallelism, maxFolders - visited)))
            queue.removeFirst(batch.count)
            visited += batch.count
            let listed = try await withThrowingTaskGroup(of: (Int, [PutioFile]).self) { group in
                for (index, folder) in batch.enumerated() {
                    group.addTask {
                        if folder.optional { return (index, (try? await putio.listFiles(parentID: folder.id).files) ?? []) }
                        return (index, try await putio.listFiles(parentID: folder.id).files)
                    }
                }
                var results: [(Int, [PutioFile])] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
            for (index, files) in listed {
                let atTop = batch[index].id == 0
                for file in files {
                    if file.isFolder {
                        onFolder(file)
                        let reads = atTop ? scope.includesTopLevelFolder(file) : !isSkippedFolder(file.name)
                        if reads, queued.insert(file.id).inserted { queue.append(Pending(id: file.id, name: file.name, optional: false)) }
                    } else if file.isVideo, !isSample(file), seenVideos.insert(file.id).inserted {
                        videos.append(FoundVideo(file: file, folder: batch[index].name))
                    }
                }
            }
        }
        return videos
    }

    func persist() async {
        guard let lastUpdated else { return }
        await cache.save(LibrarySnapshot(entries: entries, updatedAt: lastUpdated, folders: Array(folderTree.folders.values),
                                         durations: durations, scope: entriesScope, positions: positions,
                                         hiddenCards: hiddenCards.isEmpty ? nil : hiddenCards))
    }

    /// Folders that only hold subtitles, samples or artwork: not read (a season pack's "Subs" folder alone can hold
    /// a folder per episode).
    public nonisolated static func isSkippedFolder(_ name: String) -> Bool {
        ["subs", "subtitles", "sub", "sample", "samples", "screens", "screenshots", "proof", "artwork", "covers"]
            .contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    nonisolated static func isSample(_ file: PutioFile) -> Bool {
        file.name.lowercased().contains("sample") && (file.size ?? 0) < 300_000_000
    }

    enum MatchOutcome: Sendable {
        case matched(LibraryMatch)
        case noMatch
        case failed
    }

    /// Matches with up to two retries (after 1.5 s and 3 s) when TMDB fails or rate-limits.
    static func matchOutcome(_ entry: LibraryEntry, _ matcher: LibraryMatcher) async -> MatchOutcome {
        for attempt in 0..<3 {
            do {
                return try await match(entry, matcher).map(MatchOutcome.matched) ?? .noMatch
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(1500 * (attempt + 1))) }
            }
        }
        return .failed
    }

    static func match(_ entry: LibraryEntry, _ matcher: LibraryMatcher) async throws -> LibraryMatch? {
        if let match = try await matcher.match(fileName: entry.file.name) { return match }
        guard let folder = entry.folderName, let match = try await matcher.match(fileName: folder) else { return nil }
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
