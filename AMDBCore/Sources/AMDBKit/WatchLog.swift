import AMDBCore
import Foundation

/// One play, as the user's Apple devices tell each other about it: enough to order Continue Watching by what was
/// watched last anywhere, and to show a file the other device's library doesn't have yet.
public struct WatchLogEntry: Codable, Sendable, Equatable {
    public var fileID: Int64
    /// put.io file name (shown when there's no title match).
    public var name: String?
    public var tmdbID: Int?
    public var kind: MediaKind?
    public var season: Int?
    public var episode: Int?
    public var title: String?
    public var posterPath: String?
    /// Resume position; 0 once it was watched to the end.
    public var seconds: Int
    public var duration: Int?
    public var at: Date
    public var device: String?
    /// Watched (`Watched`) at `at`: a show's next episode is up next on every device. Absent from older builds.
    public var watched: Bool?

    public init(fileID: Int64, name: String? = nil, tmdbID: Int? = nil, kind: MediaKind? = nil, season: Int? = nil,
                episode: Int? = nil, title: String? = nil, posterPath: String? = nil, seconds: Int, duration: Int? = nil,
                at: Date, device: String? = nil, watched: Bool? = nil) {
        self.fileID = fileID; self.name = name; self.tmdbID = tmdbID; self.kind = kind; self.season = season
        self.episode = episode; self.title = title; self.posterPath = posterPath; self.seconds = seconds
        self.duration = duration; self.at = at; self.device = device; self.watched = watched
    }

    public var isWatched: Bool { watched == true }

    /// The library entry it stands for, from what the log knows.
    var entry: LibraryEntry {
        let match = tmdbID.flatMap { id in
            kind.map { LibraryMatch(tmdbID: id, mediaType: $0, season: season, episode: episode, confidence: 1,
                                    title: title ?? "", posterPath: posterPath) }
        }
        return LibraryEntry(file: PutioFile(id: fileID, name: name ?? title ?? "Video", fileType: "VIDEO"), match: match,
                            folderName: nil)
    }
}

public enum WatchLog {
    /// Plays kept: enough for Continue Watching, small enough for one Keychain item.
    public static let limit = 40

    /// One entry per file (its newest play), newest first, at most `limit`.
    public static func merged(_ a: [WatchLogEntry], _ b: [WatchLogEntry], limit: Int = limit) -> [WatchLogEntry] {
        var newest: [Int64: WatchLogEntry] = [:]
        for entry in a + b where (newest[entry.fileID]?.at ?? .distantPast) < entry.at { newest[entry.fileID] = entry }
        return Array(newest.values.sorted { $0.at > $1.at }.prefix(limit))
    }

    static func encode(_ entries: [WatchLogEntry]) -> Data? { try? JSONEncoder().encode(entries) }
    static func decode(_ data: Data?) -> [WatchLogEntry] {
        data.flatMap { try? JSONDecoder().decode([WatchLogEntry].self, from: $0) } ?? []
    }

    /// The Keychain account for one put.io account's log, so another account never sees it.
    public static func account(for putio: PutioAccount) -> String {
        "watchlog." + (putio.userId.map(String.init) ?? putio.username.lowercased())
    }
}

/// Where the log lives: one item per put.io account.
public protocol WatchLogStore: Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String)
}

/// One synchronizable iCloud Keychain item per put.io account, next to the synced keys (`KeychainTokenStore`).
public struct KeychainWatchLogStore: WatchLogStore {
    private let service: String

    public init(service: String = "app.amdb.tokens") { self.service = service }

    public func read(account: String) -> Data? { Keychain.read(service: service, account: account) }
    public func write(_ data: Data, account: String) {
        Keychain.write(data, service: service, account: account, synchronizes: true)
    }
}

public final class InMemoryWatchLogStore: WatchLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}
    public func read(account: String) -> Data? { lock.withLock { items[account] } }
    public func write(_ data: Data, account: String) { lock.withLock { items[account] = data } }
}

/// This device's copy of the shared log: plays are added as they happen and written to the Keychain item; the item is
/// read back (with what other devices wrote) on launch and whenever the app comes back.
@MainActor
public final class WatchLogSync {
    private let store: (any WatchLogStore)?
    public let deviceName: String
    /// Merged log, newest first.
    public private(set) var entries: [WatchLogEntry] = []
    /// The put.io account's item; nil until the account is known (plays wait in `entries` meanwhile).
    public private(set) var account: String?
    private var unsaved = false

    /// No store (demo mode, tests): nothing is read or written.
    public init(store: (any WatchLogStore)?, deviceName: String = "This device") {
        self.store = store
        self.deviceName = deviceName
    }

    public var isEnabled: Bool { store != nil }

    /// Switches to a put.io account's log (nil: signed out, forget everything).
    public func use(account: String?) {
        guard account != self.account else { return }
        // Plays recorded before the account was known belong to it; another account's never carry over.
        if self.account != nil || account == nil { entries = []; unsaved = false }
        self.account = account
        if unsaved { sync() }
    }

    /// Reads what every device wrote and merges it in (writing back plays only this device had). Returns the log.
    @discardableResult
    public func pull() -> [WatchLogEntry] {
        sync()
        return entries
    }

    /// A play on this device (playback paused or stopped, the app left, the video ended).
    public func record(_ entry: WatchLogEntry) {
        guard store != nil else { return }
        var entry = entry
        entry.device = entry.device ?? deviceName
        entries = WatchLog.merged(entries, [entry])
        unsaved = true
        sync()
    }

    /// Writes anything not written yet (the app is going to the background).
    public func flush() {
        if unsaved { sync() }
    }

    /// Merges with the item as it is now (a play another device just wrote isn't lost) and writes it if that changed it.
    private func sync() {
        guard let store, let account else { return }
        let stored = WatchLog.decode(store.read(account: account))
        entries = WatchLog.merged(entries, stored)
        if entries != stored, let data = WatchLog.encode(entries) { store.write(data, account: account) }
        unsaved = false
    }
}
