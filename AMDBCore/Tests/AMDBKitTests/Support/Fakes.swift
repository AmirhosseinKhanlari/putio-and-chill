import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

final class FakePutio: PutioService, @unchecked Sendable {
    private let lock = NSLock()
    private var children: [Int64: [PutioFile]] = [:]
    private var filesByID: [Int64: PutioFile] = [:]
    private var transfersByID: [Int64: PutioTransfer] = [:]
    private var nextID: Int64 = 1000
    private(set) var added: [(url: String, parent: Int64?)] = []
    private(set) var startFromSets: [(fileID: Int64, seconds: Int)] = []
    private(set) var createdFolders: [String] = []
    private(set) var listCalls = 0

    func add(_ file: PutioFile, to parent: Int64) {
        lock.withLock {
            children[parent, default: []].append(file)
            filesByID[file.id] = file
        }
    }

    func setTransfer(_ transfer: PutioTransfer) { lock.withLock { transfersByID[transfer.id] = transfer } }

    private(set) var accountCalls = 0
    /// Answers account info slowly (to race two refreshes).
    var accountDelays: [Duration] = []
    func accountInfo() async throws -> PutioAccount {
        let (delay, disk, trash) = lock.withLock { () -> (Duration, PutioAccount.Disk, Int64) in
            accountCalls += 1
            let delay = accountDelays.isEmpty ? .zero : accountDelays.removeFirst()
            return (delay, disk, trashed.reduce(0) { $0 + ($1.size ?? 0) })
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return PutioAccount(username: "me", userId: accountUserID, disk: disk, trashSize: trash)
    }

    func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer {
        lock.withLock {
            nextID += 1
            let transfer = PutioTransfer(id: nextID, name: "t", status: "IN_QUEUE", percentDone: 0)
            transfersByID[transfer.id] = transfer
            added.append((url, saveParentID))
            return transfer
        }
    }

    func transfer(id: Int64) async throws -> PutioTransfer {
        guard let transfer = lock.withLock({ transfersByID[id] }) else { throw AppError.http(service: "putio", status: 404) }
        return transfer
    }

    func transfers() async throws -> [PutioTransfer] { lock.withLock { Array(transfersByID.values) } }
    func cancelTransfers(ids: [Int64]) async throws { lock.withLock { ids.forEach { transfersByID[$0] = nil } } }
    func retryTransfer(id: Int64) async throws -> PutioTransfer { try await transfer(id: id) }

    func listFiles(parentID: Int64) async throws -> PutioFileList {
        try lock.withLock {
            listCalls += 1
            // Like put.io: a deleted folder can't be listed.
            if deletedFolders.contains(parentID) { throw AppError.http(service: "putio", status: 404) }
            return PutioFileList(parent: filesByID[parentID], files: children[parentID] ?? [])
        }
    }

    /// Moves or renames of these ids fail (put.io refusing, or the connection dropping mid-way).
    var failingMoves: Set<Int64> = []
    var failingRenames: Set<Int64> = []
    /// Runs after each successful move (e.g. a download landing in a folder meanwhile).
    var afterMove: (@Sendable () -> Void)?
    private var deletedFolders: Set<Int64> = []

    /// Every file and folder inside `parent`, at any depth.
    func everything(in parent: Int64) -> [PutioFile] {
        lock.withLock {
            var found: [PutioFile] = []
            var queue = [parent]
            while let next = queue.popLast() {
                for file in children[next] ?? [] {
                    found.append(file)
                    if file.isFolder { queue.append(file.id) }
                }
            }
            return found
        }
    }

    /// The names inside a folder, sorted (for checking where things ended up).
    func names(in parent: Int64) -> [String] { lock.withLock { (children[parent] ?? []).map(\.name).sorted() } }

    func file(id: Int64) async throws -> PutioFile {
        guard let file = lock.withLock({ filesByID[id] }) else { throw AppError.http(service: "putio", status: 404) }
        return file
    }

    func createFolder(name: String, parentID: Int64) async throws -> PutioFile {
        let folder = lock.withLock { () -> PutioFile in
            nextID += 1
            createdFolders.append(name)
            return PutioFile(id: nextID, name: name, fileType: "FOLDER", parentId: parentID)
        }
        add(folder, to: parentID)
        return folder
    }

    private(set) var moved: [(ids: [Int64], parent: Int64)] = []
    func moveFiles(ids: [Int64], to parentID: Int64) async throws {
        try lock.withLock {
            if !failingMoves.isDisjoint(with: ids) { throw AppError.http(service: "putio", status: 500) }
            moved.append((ids, parentID))
            for id in ids {
                guard let file = filesByID[id] else { continue }
                for key in children.keys { children[key]?.removeAll { $0.id == id } }
                let movedFile = PutioFile(id: file.id, name: file.name, fileType: file.fileType, contentType: file.contentType,
                                          size: file.size, parentId: parentID, createdAt: file.createdAt, updatedAt: file.updatedAt,
                                          startFrom: file.startFrom)
                filesByID[id] = movedFile
                children[parentID, default: []].append(movedFile)
            }
        }
        afterMove?()
    }

    private(set) var deleted: [Int64] = []
    private(set) var trashed: [PutioTrashFile] = []
    var disk = PutioAccount.Disk(avail: 600, size: 1000, used: 400)
    /// Makes copy fail after this many copies.
    var copyLimit = Int.max
    func deleteFiles(ids: [Int64]) async throws {
        lock.withLock {
            deleted += ids
            for id in ids {
                if let file = filesByID[id] {
                    trashed.append(PutioTrashFile(id: id, name: file.name, fileType: file.fileType, size: file.size,
                                                  deletedAt: "2026-10-14T10:00:0\(trashed.count % 10)"))
                }
                if filesByID[id]?.isFolder == true { deletedFolders.insert(id) }
                filesByID[id] = nil
                for key in children.keys { children[key]?.removeAll { $0.id == id } }
            }
        }
    }

    /// Files Apple devices can't play until converted, and how far each conversion is (nil = not started).
    var needsMp4: Set<Int64> = []
    var mp4Progress: [Int64: [PutioMp4Status]] = [:]
    private(set) var conversionsStarted: [Int64] = []
    func fileStatus(id: Int64) async throws -> PutioFile {
        let file = try await file(id: id)
        let done = lock.withLock { mp4Progress[id]?.first?.status == .completed }
        return PutioFile(id: file.id, name: file.name, fileType: file.fileType, size: file.size,
                         needConvert: lock.withLock { needsMp4.contains(id) }, isMp4Available: done)
    }
    /// Codecs per file, as put.io's media info reports them (unset: nothing known).
    var codecs: [Int64: (video: [String], audio: [String])] = [:]
    private(set) var mediaInfoRequests: [Int64] = []
    func mediaInfo(fileID: Int64) async throws -> PutioMediaInfo {
        lock.withLock {
            mediaInfoRequests.append(fileID)
            let known = codecs[fileID]
            return PutioMediaInfo(videoCodecs: known?.video ?? [], audioCodecs: known?.audio ?? [],
                                  needConvert: needsMp4.contains(fileID), isMp4Available: mp4Progress[fileID]?.first?.status == .completed)
        }
    }
    func mp4Status(fileID: Int64) async throws -> PutioMp4Status {
        lock.withLock {
            guard var steps = mp4Progress[fileID], !steps.isEmpty else { return PutioMp4Status(status: .notAvailable) }
            let current = steps.removeFirst()
            mp4Progress[fileID] = steps.isEmpty ? [current] : steps
            return current
        }
    }
    func convertToMp4(fileID: Int64) async throws -> PutioMp4Status {
        lock.withLock {
            conversionsStarted.append(fileID)
            if mp4Progress[fileID] == nil {
                mp4Progress[fileID] = [PutioMp4Status(status: .converting, percentDone: 40), PutioMp4Status(status: .completed, percentDone: 100)]
            }
            return PutioMp4Status(status: .inQueue)
        }
    }

    private(set) var renamed: [(id: Int64, name: String)] = []
    func renameFile(id: Int64, name: String) async throws {
        try lock.withLock {
            if failingRenames.contains(id) { throw AppError.http(service: "putio", status: 500) }
            renamed.append((id, name))
            guard let file = filesByID[id] else { return }
            let renamedFile = PutioFile(id: id, name: name, fileType: file.fileType, size: file.size, parentId: file.parentId,
                                        createdAt: file.createdAt)
            filesByID[id] = renamedFile
            for key in children.keys { children[key] = children[key]?.map { $0.id == id ? renamedFile : $0 } }
        }
    }

    private(set) var copied: [(id: Int64, parent: Int64)] = []
    func copyFile(id: Int64, to parentID: Int64) async throws -> PutioFile {
        let copy = try lock.withLock { () -> PutioFile in
            guard copied.count < copyLimit, let file = filesByID[id] else { throw AppError.http(service: "putio", status: 400) }
            copied.append((id, parentID))
            nextID += 1
            return PutioFile(id: nextID, name: file.name, fileType: file.fileType, size: file.size, parentId: parentID,
                             createdAt: file.createdAt)
        }
        add(copy, to: parentID)
        return copy
    }

    func searchFiles(_ query: String) async throws -> [PutioFile] {
        lock.withLock { filesByID.values.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    }

    func trash() async throws -> PutioTrash {
        lock.withLock { PutioTrash(files: trashed, trashSize: trashed.reduce(0) { $0 + ($1.size ?? 0) }) }
    }
    func restoreFromTrash(ids: [Int64]) async throws {
        lock.withLock {
            for file in trashed where ids.contains(file.id) {
                let restored = PutioFile(id: file.id, name: file.name, fileType: file.fileType, size: file.size, parentId: 0)
                children[0, default: []].append(restored)
                filesByID[file.id] = restored
            }
            trashed.removeAll { ids.contains($0.id) }
        }
    }
    func deleteFromTrash(ids: [Int64]) async throws { lock.withLock { trashed.removeAll { ids.contains($0.id) } } }
    func emptyTrash() async throws { lock.withLock { trashed = [] } }

    // put.io's own position per file (its start-from): what other devices saved, or this fake's list value.
    private var savedPositions: [Int64: Int] = [:]
    private(set) var startFromResets: [Int64] = []
    private(set) var startFromReads: [Int64] = []
    /// Saves that fail before one goes through (offline, a put.io error).
    var failingSaves = 0
    /// Reads that take this long (to time them out).
    var startFromDelay: Duration = .zero
    /// Files put.io answers 404 for.
    var missingFiles: Set<Int64> = []
    var accountUserID: Int64?

    /// Another device saved a position (or reset it with 0).
    func setPosition(_ seconds: Int, fileID: Int64) { lock.withLock { savedPositions[fileID] = seconds } }

    func startFrom(fileID: Int64) async throws -> Int {
        let (delay, missing) = lock.withLock { () -> (Duration, Bool) in
            startFromReads.append(fileID)
            return (startFromDelay, missingFiles.contains(fileID))
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if missing { throw AppError.http(service: "putio", status: 404) }
        return lock.withLock { savedPositions[fileID] ?? filesByID[fileID]?.startFrom ?? 0 }
    }
    func setStartFrom(fileID: Int64, seconds: Int) async throws {
        try lock.withLock {
            if failingSaves > 0 { failingSaves -= 1; throw AppError.transport("offline") }
            startFromSets.append((fileID, seconds))
            savedPositions[fileID] = seconds
        }
    }
    func resetStartFrom(fileID: Int64) async throws {
        try lock.withLock {
            if failingSaves > 0 { failingSaves -= 1; throw AppError.transport("offline") }
            startFromResets.append(fileID)
            savedPositions[fileID] = 0
        }
    }
    func hlsURL(fileID: Int64, subtitles: Bool) -> URL { URL(string: "https://hls.test/\(fileID).m3u8\(subtitles ? "?subs" : "")")! }
    func hlsURL(fileID: Int64, subtitleKey: String) -> URL { URL(string: "https://hls.test/\(fileID).m3u8?subtitle_key=\(subtitleKey)")! }
    var subtitleTracks: [PutioSubtitle] = []
    func subtitles(fileID: Int64) async throws -> [PutioSubtitle] { subtitleTracks }
    func subtitleText(fileID: Int64, key: String) async throws -> String { "1\n00:00:01,000 --> 00:00:02,000\nput.io \(key)\n" }
    func originalURL(fileID: Int64) async throws -> URL { URL(string: "https://file.test/\(fileID)")! }
}

struct FakeCatalog: CatalogService {
    var multi: [String: [CatalogItem]] = [:]
    var trendingItems: [CatalogItem] = []
    var popularMovies: [CatalogItem] = []
    var popularShows: [CatalogItem] = []
    var details: [Int: TitleDetail] = [:]
    var seasons: [Int: [Episode]] = [:]
    var movieSearch: [String: [CatalogItem]] = [:]
    var tvSearch: [String: [CatalogItem]] = [:]
    var failAll = false
    /// Makes title searches slow, to look at a refresh while it's still matching.
    var searchDelay: Duration = .zero
    /// Records the rating filters discover was asked for.
    var discoverCalls: DiscoverCalls?
    var multiPages: [String: [Int: [CatalogItem]]] = [:]
    var multiTotalPages = 1
    var imdb: [String: CatalogItem] = [:]
    /// Seasons per show id (`number_of_seasons`); unknown when absent.
    var seasonCounts: [Int: Int] = [:]
    func seasonCount(tvID: Int) async throws -> Int? { try guarded(seasonCounts[tvID]) }
    func findByIMDb(_ imdbID: String) async throws -> CatalogItem? { try guarded(imdb[imdbID]) }

    private func guarded<T>(_ value: T) throws -> T {
        if failAll { throw AppError.transport("offline") }
        return value
    }

    func validate() async throws { _ = try guarded(()) }
    func searchMulti(_ query: String) async throws -> [CatalogItem] { try guarded(multi[query.lowercased()] ?? []) }
    func searchMulti(_ query: String, page: Int) async throws -> CatalogPage {
        let items = page == 1 ? (multi[query.lowercased()] ?? []) : (multiPages[query.lowercased()]?[page] ?? [])
        return try guarded(CatalogPage(items: items, page: page, totalPages: multiTotalPages))
    }
    func trending(_ kind: MediaKind?) async throws -> [CatalogItem] { try guarded(trendingItems) }
    func popular(_ kind: MediaKind) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func topRated(_ kind: MediaKind) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail {
        guard let detail = details[id] else { throw AppError.http(service: "tmdb", status: 404) }
        return try guarded(detail)
    }
    func season(tvID: Int, number: Int) async throws -> [Episode] { try guarded(seasons[number] ?? []) }
    var people: [Int: PersonDetail] = [:]
    var collections: [Int: CollectionDetail] = [:]
    var discovered: [CatalogItem] = []
    func person(id: Int) async throws -> PersonDetail {
        guard let person = people[id] else { throw AppError.http(service: "tmdb", status: 404) }
        return try guarded(person)
    }
    func collection(id: Int) async throws -> CollectionDetail {
        guard let collection = collections[id] else { throw AppError.http(service: "tmdb", status: 404) }
        return try guarded(collection)
    }
    func discover(_ kind: MediaKind, genreIDs: [Int], minRating: Double, minVotes: Int, page: Int) async throws -> CatalogPage {
        discoverCalls?.append(minRating: minRating, minVotes: minVotes)
        return try guarded(CatalogPage(items: page == 1 ? discovered : [], page: page, totalPages: 1))
    }
    func item(_ kind: MediaKind, id: Int) async throws -> CatalogItem {
        if let detail = details[id] { return try guarded(detail.item) }
        return try guarded(CatalogItem(tmdbID: id, mediaType: kind, title: "Title \(id)", posterPath: "/p\(id).jpg"))
    }
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] {
        if searchDelay > .zero { try? await Task.sleep(for: searchDelay) }
        return try guarded(movieSearch[title.lowercased()] ?? [])
    }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] {
        if searchDelay > .zero { try? await Task.sleep(for: searchDelay) }
        return try guarded(tvSearch[title.lowercased()] ?? [])
    }
}

struct FakeSearcher: ReleaseSearching {
    var snapshots: [ReleaseSnapshot]
    func stream(for query: MediaQuery) -> AsyncStream<ReleaseSnapshot> {
        AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }
}

struct FakeProvider: SourceProvider {
    let id: String
    func releases(for query: MediaQuery) async throws -> [Release] { [] }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func movie(_ id: Int, _ title: String, year: Int? = 2024, backdrop: String? = "/b\(0).jpg") -> CatalogItem {
    CatalogItem(tmdbID: id, mediaType: .movie, title: title, posterPath: "/p\(id).jpg", backdropPath: backdrop, year: year)
}

func show(_ id: Int, _ title: String, year: Int? = 2022) -> CatalogItem {
    CatalogItem(tmdbID: id, mediaType: .tv, title: title, posterPath: "/p\(id).jpg", backdropPath: "/b\(id).jpg", year: year)
}

func makeRelease(_ hashChar: Character, seeders: Int, name: String) -> Release {
    let hash = String(repeating: hashChar, count: 40)
    return Release(name: name, link: "magnet:?xt=urn:btih:\(hash)", seeders: seeders, sources: [SourceTag(.direct, "TPB")])
}

func testDefaults() -> UserDefaults { UserDefaults(suiteName: "amdb.test.\(UUID().uuidString)")! }

final class FakeRatings: RatingsService, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var asked: [(imdbID: String?, tmdbID: Int?)] = []
    let result: Ratings
    var fail = false

    init(result: Ratings = Ratings(imdb: 8.1, tomatoes: 91, popcorn: 88)) { self.result = result }

    var calls: Int { lock.withLock { count } }
    var lookups: [(imdbID: String?, tmdbID: Int?)] { lock.withLock { asked } }

    func ratings(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Ratings {
        lock.withLock { count += 1; asked.append((imdbID, tmdbID)) }
        if fail { throw AppError.unauthorized(service: "mdblist") }
        return result
    }

    func validate() async throws { if fail { throw AppError.unauthorized(service: "mdblist") } }
}

final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

final class FakeCharts: ChartsService, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var ratingCount = 0
    /// What `rating(imdbID:tmdbID:kind:)` answers.
    var traktRating: Double?
    var calls: Int { lock.withLock { count } }
    var ratingCalls: Int { lock.withLock { ratingCount } }
    func rating(imdbID: String?, tmdbID: Int?, kind: MediaKind) async throws -> Double? {
        lock.withLock { ratingCount += 1 }
        return traktRating
    }
    func chart(_ chart: IMDbChart) async throws -> [ChartEntry] {
        lock.withLock { count += 1 }
        return [ChartEntry(rank: 1, kind: chart.kind, title: "First", year: 1994, imdbID: "tt1", tmdbID: 278),
                ChartEntry(rank: 2, kind: chart.kind, title: "No TMDB", year: 2000, imdbID: "tt2", tmdbID: nil)]
    }
}

final class DiscoverCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(minRating: Double, minVotes: Int)] = []
    var all: [(minRating: Double, minVotes: Int)] { lock.withLock { calls } }
    func append(minRating: Double, minVotes: Int) { lock.withLock { calls.append((minRating, minVotes)) } }
}
