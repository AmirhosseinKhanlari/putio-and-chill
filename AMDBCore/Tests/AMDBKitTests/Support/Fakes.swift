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

    func accountInfo() async throws -> PutioAccount { PutioAccount(username: "me") }

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
        lock.withLock {
            listCalls += 1
            return PutioFileList(parent: filesByID[parentID], files: children[parentID] ?? [])
        }
    }

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

    func startFrom(fileID: Int64) async throws -> Int { lock.withLock { filesByID[fileID]?.startFrom ?? 0 } }
    func setStartFrom(fileID: Int64, seconds: Int) async throws { lock.withLock { startFromSets.append((fileID, seconds)) } }
    func hlsURL(fileID: Int64) -> URL { URL(string: "https://hls.test/\(fileID).m3u8")! }
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

    private func guarded<T>(_ value: T) throws -> T {
        if failAll { throw AppError.transport("offline") }
        return value
    }

    func validate() async throws { _ = try guarded(()) }
    func searchMulti(_ query: String) async throws -> [CatalogItem] { try guarded(multi[query.lowercased()] ?? []) }
    func trending(_ kind: MediaKind?) async throws -> [CatalogItem] { try guarded(trendingItems) }
    func popular(_ kind: MediaKind) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func topRated(_ kind: MediaKind) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem] { try guarded(kind == .movie ? popularMovies : popularShows) }
    func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail {
        guard let detail = details[id] else { throw AppError.http(service: "tmdb", status: 404) }
        return try guarded(detail)
    }
    func season(tvID: Int, number: Int) async throws -> [Episode] { try guarded(seasons[number] ?? []) }
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] { try guarded(movieSearch[title.lowercased()] ?? []) }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] { try guarded(tvSearch[title.lowercased()] ?? []) }
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
    let result: Ratings
    var fail = false

    init(result: Ratings = Ratings(imdb: 8.1, tomatoes: 91, popcorn: 88)) { self.result = result }

    var calls: Int { lock.withLock { count } }

    func ratings(imdbID: String, kind: MediaKind) async throws -> Ratings {
        lock.withLock { count += 1 }
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
