import AMDBCore
import Foundation

/// Bridges the player to put.io's `start_from`: periodic saves, and a reset once the video is basically over.
/// Each save is noted in the library first (stamped, so the newest position wins everywhere), then sent to put.io;
/// a save put.io didn't get stays pending in the library and is sent at the next chance.
@MainActor
public final class PlaybackSession {
    public let fileID: Int64
    public let resumeFrom: Int
    private let putio: any PutioService
    private weak var library: LibraryIndex?
    private let store: LocalStore?
    private let saveEvery: Int
    private var lastSaved: Int
    /// What's playing, so a file the library doesn't have yet shows in Continue Watching as soon as it's started.
    private let entry: LibraryEntry?
    /// The list of recent plays shared with the user's other Apple devices.
    private weak var watchLog: WatchLogSync?
    /// Wait before the one retry of a save put.io didn't take.
    private let retryDelay: Duration
    /// The end was already told to the other devices (a tick past 95% does it once).
    private var loggedEnd = false
    /// When the newest save happened: an older one doesn't retry over it.
    private var latestSave: Date?

    public init(fileID: Int64, resumeFrom: Int, putio: any PutioService, library: LibraryIndex?,
                store: LocalStore? = nil, saveEvery: Int = 10, entry: LibraryEntry? = nil, watchLog: WatchLogSync? = nil,
                retryDelay: Duration = .seconds(1)) {
        self.entry = entry
        self.fileID = fileID
        self.resumeFrom = resumeFrom
        self.putio = putio
        self.library = library
        self.store = store
        self.saveEvery = saveEvery
        self.lastSaved = resumeFrom
        self.watchLog = watchLog
        self.retryDelay = retryDelay
    }

    public var shouldOfferResume: Bool { resumeFrom > 30 }
    /// Streams without put.io's subtitle tracks: the app shows put.io and OpenSubtitles subtitles itself,
    /// so Apple's player has no second subtitles menu.
    public var streamURL: URL { putio.hlsURL(fileID: fileID, subtitles: false) }

    public func tick(seconds: Double, duration: Double) async {
        let position = Int(seconds)
        guard abs(position - lastSaved) >= saveEvery else { return }
        await save(position, duration: duration, checkpoint: false)
    }

    /// Saves the position now, however recently it was saved: playback paused or the player is closing, or the app is
    /// leaving the screen. Also tells the user's other devices (not every tick: that's what put.io is for).
    public func finish(seconds: Double, duration: Double) async {
        await save(Int(seconds), duration: duration, checkpoint: true)
    }

    private func save(_ position: Int, duration: Double, checkpoint: Bool) async {
        lastSaved = position
        let watchedToEnd = duration > 0 && Double(position) >= duration * 0.95
        let value = watchedToEnd ? 0 : position
        let at = Date()
        latestSave = at
        if duration.isFinite, duration > 0 { library?.noteDuration(fileID: fileID, seconds: Int(duration)) }
        if let entry, value >= 30 { library?.notePlayed(entry) }
        library?.noteProgress(fileID: fileID, seconds: value, now: at)
        if watchedToEnd, let store {
            let id = fileID
            await store.update { state in
                if !state.finished.contains(where: { $0.fileID == id }) { state.finished.append(FinishedFile(fileID: id, at: Date())) }
            }
        }
        if checkpoint || (watchedToEnd && !loggedEnd) {
            loggedEnd = watchedToEnd
            watchLog?.record(logEntry(seconds: value, duration: duration, at: at))
        }
        if await send(value, savedAt: at) {
            library?.markSent(fileID: fileID, at: at)
            // put.io is reachable again: anything an earlier save couldn't send goes now.
            if let library, !library.pendingPositions.isEmpty { await library.sendPending() }
        }
    }

    /// Sends the position to put.io, once more after `retryDelay` if that fails (unless a newer save came meanwhile:
    /// it would be overwritten with this older one). Returns whether put.io has it.
    private func send(_ value: Int, savedAt: Date) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0, latestSave != savedAt { return false }
            do {
                try await LibraryIndex.send(value, fileID: fileID, to: putio)
                return true
            } catch {
                if attempt == 0 { try? await Task.sleep(for: retryDelay) }
            }
        }
        return false
    }

    private func logEntry(seconds: Int, duration: Double, at: Date) -> WatchLogEntry {
        let match = entry?.match
        return WatchLogEntry(fileID: fileID, name: entry?.file.name, tmdbID: match?.tmdbID, kind: match?.mediaType,
                             season: match?.season, episode: match?.episode, title: match?.title,
                             posterPath: match?.posterPath, seconds: seconds,
                             duration: duration.isFinite && duration > 0 ? Int(duration) : nil, at: at)
    }
}
