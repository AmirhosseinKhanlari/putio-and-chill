import AMDBCore
import Foundation

/// Resume positions across devices. put.io holds the value every device shares (read with `startFrom`, written with
/// `setStartFrom` / `resetStartFrom`); each one is kept with when it was true, and the newest wins (`WatchProgress`).
extension LibraryIndex {
    /// How long a position check may wait for put.io before the app goes on without it.
    public static let positionTimeout: Duration = .seconds(4)

    /// When the file was last watched anywhere, if known.
    public func watchedAt(fileID: Int64) -> Date? { positions[fileID]?.watchedAt }

    /// Watched to the end (`Watched`) on any device, and not rewatched since.
    public func isWatched(fileID: Int64) -> Bool { positions[fileID]?.isWatched ?? false }
    public func isWatched(_ entry: LibraryEntry) -> Bool { isWatched(fileID: entry.id) }

    /// Positions in put.io's file list. That field isn't documented, so only a started position counts: a missing or
    /// zero value never removes one (the file's own start-from, read by `checkPositions`, does that).
    func notePutioList(_ files: [PutioFile], readAt: Date, firstRead: Bool) {
        for file in files {
            guard let seconds = file.startFrom, seconds > 0 else { continue }
            // On the very first read there's nothing to compare with, so it says nothing about when it was watched.
            let incoming = WatchProgress(seconds: seconds, at: readAt, source: .putio, watchedAt: firstRead ? nil : readAt)
            let merged = WatchProgress.merged(positions[file.id], incoming)
            if merged != positions[file.id] { positions[file.id] = merged }
        }
    }

    /// Positions read from put.io's start-from (as of `readAt`, when the reads began). A changed value means the file
    /// was watched since, somewhere; 0 means it was reset (watched to the end elsewhere).
    public func notePutioPositions(_ values: [Int64: Int], readAt: Date) {
        guard !values.isEmpty else { return }
        for (id, seconds) in values {
            let incoming = WatchProgress(seconds: seconds, at: readAt, source: .putio, watchedAt: seconds > 0 ? readAt : nil)
            let merged = WatchProgress.merged(positions[id], incoming)
            if merged != positions[id] { positions[id] = merged }
        }
        Task { await persist() }
    }

    /// Plays from the user's other Apple devices (`WatchLog`): newer positions win, and a file this library doesn't
    /// have shows from what the log knows about it until the next update.
    public func noteOtherDevices(_ log: [WatchLogEntry]) {
        guard !log.isEmpty else { return }
        for item in log {
            let incoming = WatchProgress(seconds: item.seconds, at: item.at, source: .otherDevice, watchedAt: item.at,
                                         finishedAt: item.isWatched ? item.at : nil)
            let merged = WatchProgress.merged(positions[item.fileID], incoming)
            if merged != positions[item.fileID] { positions[item.fileID] = merged }
            if let duration = item.duration, duration > 0, durations[item.fileID] == nil { durations[item.fileID] = duration }
            // A watched episode too: its show's next one is up next.
            if merged.seconds >= 30 || merged.isWatched, !goneFiles.contains(item.fileID),
               !entries.contains(where: { $0.id == item.fileID }) {
                notePlayed(item.entry)
            }
        }
        Task { await persist() }
    }

    /// put.io has the position saved at `at` (nothing newer was saved meanwhile).
    public func markSent(fileID: Int64, at: Date) {
        guard var record = positions[fileID], record.pending, record.at == at else { return }
        record.pending = false
        positions[fileID] = record
        Task { await persist() }
    }

    /// Positions saved here that put.io doesn't have yet.
    public var pendingPositions: [(fileID: Int64, seconds: Int, at: Date)] {
        positions.filter(\.value.pending).map { ($0.key, $0.value.seconds, $0.value.at) }.sorted { $0.at < $1.at }
    }

    /// Sends positions put.io didn't get when they were saved (offline, an error). A file put.io no longer has is
    /// given up on.
    public func sendPending() async {
        guard let putio = putioService else { return }
        for item in pendingPositions {
            do {
                try await Self.send(item.seconds, fileID: item.fileID, to: putio)
                markSent(fileID: item.fileID, at: item.at)
            } catch AppError.http(_, status: 404) {
                markSent(fileID: item.fileID, at: item.at)
            } catch {
                continue
            }
        }
    }

    /// Saves a position in put.io (0 forgets it: watched to the end).
    nonisolated static func send(_ seconds: Int, fileID: Int64, to putio: any PutioService) async throws {
        if seconds == 0 {
            try await putio.resetStartFrom(fileID: fileID)
        } else {
            try await putio.setStartFrom(fileID: fileID, seconds: seconds)
        }
    }

    /// Reads put.io's current position for each file, `parallelism` at a time, each given up on after `timeout`
    /// (it's then left as it was). Returns the positions read.
    @discardableResult
    public func checkPositions(_ fileIDs: [Int64], timeout: Duration = positionTimeout, parallelism: Int = 6,
                               now: Date = Date()) async -> [Int64: Int] {
        guard let putio = putioService, !fileIDs.isEmpty else { return [:] }
        enum Outcome: Sendable { case position(Int), gone, unknown }
        var read: [Int64: Int] = [:]
        var gone: [Int64] = []
        await withTaskGroup(of: (Int64, Outcome).self) { group in
            var next = 0
            func add() {
                let id = fileIDs[next]
                next += 1
                group.addTask {
                    do {
                        return (id, .position(try await Self.withTimeout(timeout) { try await putio.startFrom(fileID: id) }))
                    } catch AppError.http(_, status: 404) {
                        return (id, .gone)
                    } catch {
                        return (id, .unknown)
                    }
                }
            }
            while next < min(max(parallelism, 1), fileIDs.count) { add() }
            while let (id, outcome) = await group.next() {
                switch outcome {
                case let .position(seconds): read[id] = seconds
                case .gone: gone.append(id)
                case .unknown: break
                }
                if next < fileIDs.count { add() }
            }
        }
        for id in gone {
            goneFiles.insert(id)
            dropPlayedOutside(id)
        }
        notePutioPositions(read, readAt: now)
        return read
    }

    /// The position to resume `fileID` from: put.io's current one when it answers within `timeout` (it may have been
    /// watched on another device since this one last looked), merged with what's known here; newest wins.
    public func freshResumeSeconds(fileID: Int64, timeout: Duration = .seconds(2)) async -> Int {
        await checkPositions([fileID], timeout: timeout)
        return resumeSeconds(fileID: fileID)
    }

    /// Files whose position is worth asking put.io about, newest first: what any device played lately (`log`), files
    /// with a position or watched (most recently watched first: a rewatch elsewhere brings one back), then put.io's
    /// most recently changed videos. `recentSlots` are kept for those last ones, so a long list of started files can't
    /// crowd out one started elsewhere just now.
    public func positionCandidates(log: [WatchLogEntry], limit: Int = 30, recentSlots: Int = 10) -> [Int64] {
        var ids: [Int64] = []
        var seen: Set<Int64> = []
        func add(_ id: Int64, upTo cap: Int) { if ids.count < cap, seen.insert(id).inserted { ids.append(id) } }
        let known = max(limit - recentSlots, 0)
        for item in log.sorted(by: { $0.at > $1.at }) where item.seconds >= 30 || item.isWatched { add(item.fileID, upTo: known) }
        let started = entries.filter { resumeSeconds(for: $0) >= 30 || isWatched($0) }.sorted { a, b in
            let wa = positions[a.id]?.watchedAt ?? .distantPast, wb = positions[b.id]?.watchedAt ?? .distantPast
            return wa != wb ? wa > wb : (a.file.updatedAt ?? "") > (b.file.updatedAt ?? "")
        }
        for entry in started { add(entry.id, upTo: known) }
        for entry in entries.sorted(by: { ($0.file.updatedAt ?? "") > ($1.file.updatedAt ?? "") }) { add(entry.id, upTo: limit) }
        return ids
    }

    /// Forgets put.io's and other devices' positions for files that left the library long ago (never this device's
    /// unsent ones, nor anything the library still has).
    func prunePositions(now: Date, olderThan age: TimeInterval = 60 * 86_400) {
        let ids = Set(entries.map(\.id))
        positions = positions.filter { id, record in
            ids.contains(id) || record.pending || now.timeIntervalSince(record.at) < age
        }
    }

    nonisolated static func withTimeout<T: Sendable>(_ timeout: Duration,
                                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppError.timeout(service: "putio")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AppError.timeout(service: "putio") }
            return first
        }
    }
}
