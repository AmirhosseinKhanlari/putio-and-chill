import AMDBCore
import Foundation
import Observation

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

    public init(store: LocalStore, pollInterval: Duration = .seconds(2), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.pollInterval = pollInterval
        self.now = now
    }

    public func configure(putio: (any PutioService)?, library: LibraryIndex?) {
        self.putio = putio
        self.library = library
        if putio == nil {
            stop()
            tracked = []
        }
    }

    /// Picks up transfers that were in flight when the app last quit.
    public func restore() async {
        for pending in await store.snapshot.pending where !tracked.contains(where: { $0.id == pending.transferID }) {
            tracked.append(TrackedTransfer(pending: pending, transfer: nil, phase: .queued))
        }
        await pollOnce()
        startIfNeeded()
    }

    @discardableResult
    public func send(_ release: Release, target: TransferTarget) async throws -> TrackedTransfer {
        guard let putio else { throw AppError.unauthorized(service: "putio") }
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
                                      season: target.season, episode: target.episode, createdAt: now())
        await store.update { $0.pending.append(pending) }
        tracked.append(TrackedTransfer(pending: pending, transfer: transfer, phase: TransferPhase(transfer)))
        await settle(transfer.id)
        startIfNeeded()
        return tracked.first { $0.id == transfer.id } ?? TrackedTransfer(pending: pending, transfer: transfer, phase: TransferPhase(transfer))
    }

    public func pollOnce() async {
        guard let putio else { return }
        for id in tracked.filter({ !$0.notified }).map(\.id) {
            guard let transfer = try? await putio.transfer(id: id),
                  let index = tracked.firstIndex(where: { $0.id == id }) else { continue }
            var detector = detectors[id] ?? StallDetector()
            tracked[index].transfer = transfer
            tracked[index].phase = TransferPhase(transfer)
            tracked[index].isStalled = detector.isStalled(transfer, now: now())
            detectors[id] = detector
            await settle(id)
        }
    }

    public func cancel(_ id: Int64) async throws {
        try await putio?.cancelTransfers(ids: [id])
        tracked.removeAll { $0.id == id }
        await store.update { $0.pending.removeAll { $0.transferID == id } }
    }

    public func dismiss(_ id: Int64) { tracked.removeAll { $0.id == id } }

    public func latest(tmdbID: Int, season: Int? = nil, episode: Int? = nil) -> TrackedTransfer? {
        tracked.last { $0.pending.tmdbID == tmdbID && $0.pending.season == season && $0.pending.episode == episode }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func startIfNeeded() {
        guard loop == nil, tracked.contains(where: { !$0.notified }) else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.tracked.contains(where: { !$0.notified }) {
                try? await Task.sleep(for: self.pollInterval)
                await self.pollOnce()
            }
            self?.loop = nil
        }
    }

    /// Resolves a finished transfer to its playable file, records it in the library, and emits one event.
    private func settle(_ id: Int64) async {
        guard let putio, let item = tracked.first(where: { $0.id == id }), !item.notified else { return }
        switch item.phase {
        case let .completed(fileID?):
            guard let file = try? await PlaybackResolver.playableFile(fileID, putio: putio),
                  let index = tracked.firstIndex(where: { $0.id == id }) else { return }
            tracked[index].playableFile = file
            tracked[index].notified = true
            let pending = item.pending
            if pending.tmdbID > 0 {
                await library?.record(file: file, match: LibraryMatch(
                    tmdbID: pending.tmdbID, mediaType: pending.kind, season: pending.season, episode: pending.episode,
                    confidence: 1, title: pending.title, posterPath: pending.posterPath, backdropPath: pending.backdropPath))
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
