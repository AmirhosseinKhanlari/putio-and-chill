import Foundation

/// One file's resume position and when it was known to be true. Positions come from this device's player, from
/// put.io and from the user's other Apple devices; `merged` keeps the newest, so no source silently wins.
public struct WatchProgress: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Saved by the player on this device.
        case device
        /// Read from put.io (the file's start-from, or its file list).
        case putio
        /// From the recently watched list the user's Apple devices share through iCloud Keychain (`WatchLog`).
        case otherDevice
    }

    public var seconds: Int
    /// When this position was true: saved here, read from put.io (when the read began), or saved on the other device.
    public var at: Date
    public var source: Source
    /// When the file was last watched anywhere, as far as this device knows; orders Continue Watching. nil: unknown.
    public var watchedAt: Date?
    /// Saved here but put.io doesn't have it yet: it's sent at the next chance, and put.io's older value can't replace it.
    public var pending: Bool

    public init(seconds: Int, at: Date, source: Source, watchedAt: Date? = nil, pending: Bool = false) {
        self.seconds = seconds; self.at = at; self.source = source; self.watchedAt = watchedAt; self.pending = pending
    }

    /// What to keep when `incoming` arrives while `current` is known.
    /// - A save on this device always wins (it's the newest thing that happened).
    /// - Another device's position wins when it's newer.
    /// - put.io's value replaces one this device already sent, if it was read after that was saved. It never replaces
    ///   a position put.io hasn't been sent yet. The same value just confirms put.io has it.
    public static func merged(_ current: WatchProgress?, _ incoming: WatchProgress) -> WatchProgress {
        guard let current else { return incoming }
        let watched = latest(current.watchedAt, incoming.watchedAt)
        switch incoming.source {
        case .device:
            var kept = incoming
            kept.watchedAt = watched
            return kept
        case .otherDevice:
            var kept = incoming.at > current.at ? incoming : current
            kept.watchedAt = watched
            return kept
        case .putio:
            if incoming.seconds == current.seconds {
                var kept = current
                kept.pending = false
                kept.at = max(current.at, incoming.at)
                return kept
            }
            if current.pending || current.at >= incoming.at { return current }
            var kept = incoming
            kept.watchedAt = watched
            return kept
        }
    }

    static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        default: a ?? b
        }
    }
}
