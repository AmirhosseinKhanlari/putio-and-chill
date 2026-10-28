import AMDBCore
import Foundation
import Observation
import OSLog

public struct TransferTarget: Sendable, Hashable {
    public let tmdbID: Int
    public let kind: MediaKind
    public let title: String
    public let posterPath: String?
    public let backdropPath: String?
    public let season: Int?
    public let episode: Int?

    public init(tmdbID: Int, kind: MediaKind, title: String, posterPath: String?, backdropPath: String?,
                season: Int?, episode: Int?) {
        self.tmdbID = tmdbID; self.kind = kind; self.title = title; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.season = season; self.episode = episode
    }
}

public struct TrackedTransfer: Identifiable, Sendable, Equatable {
    public let pending: PendingTransfer
    public var transfer: PutioTransfer?
    public var phase: TransferPhase
    public var isStalled = false
    public var playableFile: PutioFile?
    public var notified = false

    public var id: Int64 { pending.transferID }
    public var percent: Int { transfer?.percentDone ?? 0 }
}

public enum TransferEvent: Sendable, Equatable {
    case ready(TrackedTransfer)
    case failed(TrackedTransfer)
}

@Observable @MainActor
public final class TransferMonitor {
    public private(set) var tracked: [TrackedTransfer] = []
    @ObservationIgnored public var onEvent: (@MainActor (TransferEvent) -> Void)?

    private let store: LocalStore
    private let pollInterval: Duration
    private let now: @Sendable () -> Date
    private var putio: (any PutioService)?
    /// Where transfers are saved (from Settings).
    @ObservationIgnored public var layout = FolderLayout.standard
    @ObservationIgnored private weak var library: LibraryIndex?
    private var detectors: [Int64: StallDetector] = [:]
    private var loop: Task<Void, Never>?
    /// Which polling loop is the current one: a loop that `stop()` ended must not clear the one started after it.
    private var loopGeneration = 0
    /// Polls in a row that put.io didn't answer, per transfer (a transient error is tried again; `maxFailures` isn't).
    private var failures: [Int64: Int] = [:]
    /// Consecutive failed polls after which a transfer is reported as failed instead of being asked about forever.
    static let maxFailures = 30
    /// Makes room on put.io when a download doesn't fit (`RoomKeeper`).
    @ObservationIgnored public let room: RoomKeeper

    public init(store: LocalStore, pollInterval: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.pollInterval = pollInterval
        self.now = now
        room = RoomKeeper(store: store, now: now)
        room.busyFolders = { [weak self] in self?.busyFolders ?? [] }
        room.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case let .send(release, target): try await self.send(release, target: target, checkingSpace: false)
            case let .retry(id): try await self.retry(id)
            }
        }
    }

    public func configure(putio: (any PutioService)?, library: LibraryIndex?) {
        self.library = library
        room.configure(putio: putio, library: library)
        if putio == nil {
            let signedOut = self.putio != nil
            stop()
            tracked = []
            detectors = [:]
            failures = [:]
            // Signing out forgets the saved transfers too, so another account's launch never restores them.
            if signedOut { Task { [store] in await store.update { $0.pending = [] } } }
        }
        self.putio = putio
    }

    /// Picks up transfers that were in flight when the app last quit.
    public func restore() async {
        for pending in await store.snapshot.pending where !tracked.contains(where: { $0.id == pending.transferID }) {
            tracked.append(TrackedTransfer(pending: pending, transfer: nil, phase: .queued))
        }
        await pollOnce()
        startIfNeeded()
    }

    /// Sends a release to put.io. First checks it fits (`checkingSpace`): when it doesn't, throws `NotEnoughSpace`
    /// with what could be deleted to make room, and nothing is sent.
    @discardableResult
    public func send(_ release: Release, target: TransferTarget, checkingSpace: Bool = true) async throws -> TrackedTransfer {
        guard let putio else { throw AppError.unauthorized(service: "putio") }
        if checkingSpace { try await room.check(release, target: target) }
        let transfer: PutioTransfer
        do {
            let folder = try await layout.destinationID(kind: target.kind, title: target.title, season: target.season,
                                                        putio: putio, store: store)
            transfer = try await putio.addTransfer(url: release.link, saveParentID: folder)
        } catch AppError.http {
            // A cached folder may have been deleted in put.io; resolve again once.
            await FolderResolver.forgetAll(store: store)
            let folder = try await layout.destinationID(kind: target.kind, title: target.title, season: target.season,
                                                        putio: putio, store: store)
            transfer = try await putio.addTransfer(url: release.link, saveParentID: folder)
        }
        let pending = PendingTransfer(transferID: transfer.id, tmdbID: target.tmdbID, kind: target.kind, title: target.title,
                                      posterPath: target.posterPath, backdropPath: target.backdropPath,
                                      season: target.season, episode: target.episode, createdAt: now(), link: release.link)
        await store.update { $0.pending.append(pending) }
        tracked.append(TrackedTransfer(pending: pending, transfer: transfer, phase: TransferPhase(transfer)))
        await settle(transfer.id)
        startIfNeeded()
        return tracked.first { $0.id == transfer.id } ?? TrackedTransfer(pending: pending, transfer: transfer, phase: TransferPhase(transfer))
    }

    public func pollOnce() async {
        guard let putio else { return }
        for id in tracked.filter({ !$0.notified }).map(\.id) {
            let transfer: PutioTransfer
            do {
                transfer = try await putio.transfer(id: id)
                failures[id] = nil
            } catch AppError.http(_, status: 404) {
                // Removed on put.io's site: there's nothing left to follow, now or at the next launch.
                await forget(id)
                continue
            } catch {
                failures[id, default: 0] += 1
                if failures[id, default: 0] >= Self.maxFailures {
                    failures[id] = nil
                    await report(failed: id, "put.io stopped answering about this download. Check it on put.io.")
                }
                continue
            }
            guard let index = tracked.firstIndex(where: { $0.id == id }) else { continue }
            var detector = detectors[id] ?? StallDetector()
            tracked[index].transfer = transfer
            tracked[index].phase = TransferPhase(transfer)
            tracked[index].isStalled = detector.isStalled(transfer, now: now())
            detectors[id] = detector
            await settle(id)
        }
    }

    /// Retries a failed transfer on put.io (after making room) and follows it again.
    public func retry(_ id: Int64) async throws {
        guard let putio else { throw AppError.unauthorized(service: "putio") }
        let transfer = try await putio.retryTransfer(id: id)
        guard let old = tracked.first(where: { $0.id == id })?.pending else { return }
        let pending = PendingTransfer(transferID: transfer.id, tmdbID: old.tmdbID, kind: old.kind, title: old.title,
                                      posterPath: old.posterPath, backdropPath: old.backdropPath, season: old.season,
                                      episode: old.episode, createdAt: now(), link: old.link)
        // put.io may still report the old error for a moment: it's queued again either way.
        var phase = TransferPhase(transfer)
        if case .failed = phase { phase = .queued }
        tracked.removeAll { $0.id == id || $0.id == transfer.id }
        tracked.append(TrackedTransfer(pending: pending, transfer: transfer, phase: phase))
        detectors[id] = nil
        completedSince[id] = nil
        await store.update { state in
            state.pending.removeAll { $0.transferID == id || $0.transferID == pending.transferID }
            state.pending.append(pending)
        }
        startIfNeeded()
    }

    /// Folders running downloads save into (making room never deletes them).
    var busyFolders: Set<Int64> {
        Set(tracked.filter { !$0.notified }.compactMap { $0.transfer?.saveParentId })
    }

    public func cancel(_ id: Int64) async throws {
        try await putio?.cancelTransfers(ids: [id])
        tracked.removeAll { $0.id == id }
        await store.update { $0.pending.removeAll { $0.transferID == id } }
    }

    /// Takes a finished or failed transfer off the list, for good: it's not saved for the next launch either.
    public func dismiss(_ id: Int64) {
        tracked.removeAll { $0.id == id }
        Task { [store] in await store.update { $0.pending.removeAll { $0.transferID == id } } }
    }

    /// Drops a transfer put.io no longer has, here and from what's saved for the next launch.
    private func forget(_ id: Int64) async {
        tracked.removeAll { $0.id == id }
        detectors[id] = nil
        failures[id] = nil
        completedSince[id] = nil
        await store.update { $0.pending.removeAll { $0.transferID == id } }
    }

    public func latest(tmdbID: Int, season: Int? = nil, episode: Int? = nil) -> TrackedTransfer? {
        tracked.last { $0.pending.tmdbID == tmdbID && $0.pending.season == season && $0.pending.episode == episode }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func startIfNeeded() {
        guard loop == nil, tracked.contains(where: { !$0.notified }) else { return }
        loopGeneration += 1
        let mine = loopGeneration
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.tracked.contains(where: { !$0.notified }) {
                try? await Task.sleep(for: self.pollInterval)
                await self.pollOnce()
            }
            if let self, self.loopGeneration == mine { self.loop = nil }
        }
    }

    /// When each finished transfer was first seen finished (to stop waiting for a file that never shows up).
    private var completedSince: [Int64: Date] = [:]
    /// How long a finished transfer may take to show its file before it's reported as a problem.
    static let fileGrace: TimeInterval = 180

    /// Waits a little (put.io can take a moment to list a finished transfer's files), then reports the transfer as
    /// failed with `message` instead of showing it as downloading forever.
    private func giveUpIfStuck(_ id: Int64, _ message: String) async {
        let since = completedSince[id] ?? now()
        completedSince[id] = since
        guard now().timeIntervalSince(since) >= Self.fileGrace else { return }
        completedSince[id] = nil
        await report(failed: id, message)
    }

    /// Shows the transfer as failed with `message`, stops following it, and tells the app once.
    private func report(failed id: Int64, _ message: String) async {
        guard let index = tracked.firstIndex(where: { $0.id == id }) else { return }
        tracked[index].phase = .failed(message: message)
        tracked[index].notified = true
        let failed = tracked[index]
        await store.update { $0.pending.removeAll { $0.transferID == id } }
        onEvent?(.failed(failed))
    }

    static let log = Logger(subsystem: "app.amdb", category: "release-safety")

    /// A finished download that holds a program or no video: deleted from put.io (to its trash), its release
    /// remembered so it's never offered again, and reported as failed so the title offers another version.
    private func discardFake(_ id: Int64, fileID: Int64, reason: String) async {
        guard let item = tracked.first(where: { $0.id == id }) else { return }
        try? await putio?.deleteFiles(ids: [fileID])
        let keys = DownloadCheck.badReleaseKeys(hash: item.transfer?.hash, link: item.pending.link)
        #if DEBUG
        Self.log.debug("Removed fake download \(item.transfer?.name ?? item.pending.title, privacy: .public): \(reason, privacy: .public)")
        #endif
        await store.update { state in
            state.pending.removeAll { $0.transferID == id }
            state.badReleases.formUnion(keys)
        }
        completedSince[id] = nil
        guard let index = tracked.firstIndex(where: { $0.id == id }) else { return }
        tracked[index].phase = .failed(message: DownloadCheck.fakeMessage)
        tracked[index].notified = true
        onEvent?(.failed(tracked[index]))
    }

    /// The saved file or folder of a finished transfer, by its name in the folder it was saved to.
    static func findSaved(_ transfer: PutioTransfer, putio: any PutioService) async -> Int64? {
        guard let name = transfer.name, !name.isEmpty,
              let files = try? await putio.listFiles(parentID: transfer.saveParentId ?? 0).files else { return nil }
        return files.first { $0.name == name }?.id
            ?? files.first { ($0.name as NSString).deletingPathExtension == (name as NSString).deletingPathExtension }?.id
    }

    /// Resolves a finished transfer to its playable file, records it in the library, and emits one event.
    private func settle(_ id: Int64) async {
        guard let putio, let item = tracked.first(where: { $0.id == id }), !item.notified else { return }
        switch item.phase {
        case let .completed(reported):
            let pending = item.pending
            // put.io sometimes reports a finished transfer without its file: look for it by name where it was saved.
            var found = reported
            if found == nil, let transfer = item.transfer { found = await Self.findSaved(transfer, putio: putio) }
            guard let fileID = found else {
                await giveUpIfStuck(id, "Finished on put.io, but its file wasn't found. Look for it in Library → Files.")
                return
            }
            switch await DownloadCheck.inspect(fileID, putio: putio) {
            case let .program(name):
                await discardFake(id, fileID: fileID, reason: "contains a program (\(name))")
                return
            case .noVideo:
                let since = completedSince[id] ?? now()
                completedSince[id] = since
                if now().timeIntervalSince(since) >= Self.fileGrace { await discardFake(id, fileID: fileID, reason: "no video inside") }
                return
            case .video, .unknown:
                break
            }
            // A whole season: every episode in it goes into the library, and Play starts at the first one.
            var episodes: [(file: PutioFile, match: LibraryMatch)] = []
            if pending.tmdbID > 0, pending.kind == .tv, pending.season != nil, pending.episode == nil,
               let videos = try? await PlaybackResolver.videos(in: fileID, putio: putio) {
                episodes = EpisodeNumbering.packEpisodes(videos, target: pending)
            }
            let resolved = episodes.isEmpty ? try? await PlaybackResolver.playableFile(fileID, putio: putio) : episodes[0].file
            guard let file = resolved, let index = tracked.firstIndex(where: { $0.id == id }) else {
                await giveUpIfStuck(id, "Finished on put.io, but there's no video in it. Look for it in Library → Files.")
                return
            }
            tracked[index].playableFile = file
            tracked[index].notified = true
            completedSince[id] = nil
            if !episodes.isEmpty {
                await library?.record(episodes)
            } else if pending.tmdbID > 0 {
                let match = LibraryMatch(
                    tmdbID: pending.tmdbID, mediaType: pending.kind, season: pending.season, episode: pending.episode,
                    confidence: 1, title: pending.title, posterPath: pending.posterPath, backdropPath: pending.backdropPath)
                await library?.record(file: file, match: EpisodeNumbering.repaired(match, fileName: file.name) ?? match)
            }
            await store.update { $0.pending.removeAll { $0.transferID == id } }
            if let done = tracked.first(where: { $0.id == id }) { onEvent?(.ready(done)) }
        case .failed:
            guard let index = tracked.firstIndex(where: { $0.id == id }) else { return }
            tracked[index].notified = true
            await store.update { $0.pending.removeAll { $0.transferID == id } }
            if let failed = tracked.first(where: { $0.id == id }) { onEvent?(.failed(failed)) }
        default:
            break
        }
    }
}
