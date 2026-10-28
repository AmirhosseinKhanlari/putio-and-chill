import AMDBCore
import Foundation
import Observation

/// What happens once there's room.
public enum RoomAction: Sendable, Hashable {
    /// Send this release to put.io (Get & Watch, Versions).
    case send(Release, TransferTarget)
    /// Retry a put.io transfer that failed for lack of space.
    case retry(transferID: Int64)
}

/// A download that doesn't fit, with what could be deleted to make room for it.
public struct RoomOffer: Identifiable, Sendable, Hashable {
    public let id = UUID()
    /// What's being got: "Dune: Part Two", "Severance · Season 2".
    public let title: String
    public let size: Int64
    /// put.io's free space when it was checked.
    public let avail: Int64
    /// nil when making room is turned off in Settings.
    public let plan: RoomPlan?
    public let action: RoomAction
    public let target: TransferTarget?

    public init(title: String, size: Int64, avail: Int64, plan: RoomPlan?, action: RoomAction, target: TransferTarget?) {
        self.title = title; self.size = size; self.avail = avail; self.plan = plan; self.action = action; self.target = target
    }

    /// The free space it needs (its size plus `SpaceCheck.marginPercent`).
    public var required: Int64 { SpaceCheck.required(size: size) }
    /// Bytes to free.
    public var needed: Int64 { max(required - avail, 0) }
    public var canMakeRoom: Bool { plan?.isEnough == true }

    public var headline: String { "Not enough space on put.io" }
    public var message: String { "\(title) needs \(RoomFormat.bytes(size)), you have \(RoomFormat.bytes(avail)) free." }

    /// Why nothing is offered for deleting, when nothing is.
    public var explanation: String? {
        guard let plan else { return "Free up space in put.io, or turn on making room in Settings → Smart Get." }
        guard !plan.isEnough else { return nil }
        if plan.candidates.isEmpty {
            return "Nothing in Movies or TV Series can go: what's left is being watched, on My List, or what you're getting."
        }
        return "Deleting everything that can go in Movies and TV Series would free only \(RoomFormat.bytes(plan.available)). "
            + "Nothing was deleted."
    }

    static func title(for target: TransferTarget) -> String {
        switch (target.season, target.episode) {
        case let (season?, episode?): "\(target.title) · S\(season) E\(episode)"
        case let (season?, nil) where target.kind == .tv: "\(target.title) · Season \(season)"
        default: target.title
        }
    }
}

/// Thrown by `TransferMonitor.send` when the release doesn't fit; its `offer` is what the confirmation shows.
public struct NotEnoughSpace: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let offer: RoomOffer
    public var errorDescription: String? { "\(offer.headline). \(offer.message)" }
    public var description: String { errorDescription ?? "" }
}

public enum RoomFormat {
    public static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file) }
}

/// Makes room on put.io for a download that doesn't fit: checks before sending, plans what could go, and runs a
/// confirmed plan (`RoomSession`). Nothing is ever deleted without the user confirming the exact list.
@Observable @MainActor
public final class RoomKeeper {
    /// The confirmation on screen (set by `presentRefusal` or a retry), cleared when it closes.
    public var offer: RoomOffer?
    /// "Make room on put.io when a download doesn't fit" (Settings). Off: only the not-enough-space message.
    @ObservationIgnored public var isEnabled = true

    @ObservationIgnored private var putio: (any PutioService)?
    @ObservationIgnored private weak var library: LibraryIndex?
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The last refusal, so screens that got a plain failure back (Smart Get) can show it.
    @ObservationIgnored private var lastRefusal: (offer: RoomOffer, at: Date)?
    /// Folders downloads are saving into (from `TransferMonitor`).
    @ObservationIgnored var busyFolders: @MainActor () -> Set<Int64> = { [] }
    /// Sends or retries once there's room (from `TransferMonitor`).
    @ObservationIgnored var perform: @MainActor (RoomAction) async throws -> Void = { _ in }

    init(store: LocalStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    func configure(putio: (any PutioService)?, library: LibraryIndex?) {
        self.putio = putio
        self.library = library
        if putio == nil { offer = nil; lastRefusal = nil }
    }

    /// Before a release is sent: throws `NotEnoughSpace` when put.io's free space (read fresh) is short of its size
    /// plus the margin. An unknown size, or put.io not answering, lets it through.
    func check(_ release: Release, target: TransferTarget) async throws {
        guard let putio, let size = release.sizeBytes, size > 0,
              let avail = try? await putio.accountInfo().disk?.avail,
              let shortfall = SpaceCheck.shortfall(size: size, avail: avail) else { return }
        let plan = isEnabled ? await plan(needed: shortfall, target: target) : nil
        let offer = RoomOffer(title: RoomOffer.title(for: target), size: size, avail: avail, plan: plan,
                              action: .send(release, target), target: target)
        lastRefusal = (offer, now())
        throw NotEnoughSpace(offer: offer)
    }

    /// Shows the confirmation for `target` when the last send for it was refused in the past two minutes (Smart Get
    /// reports only a failure). Returns whether it did.
    @discardableResult
    public func presentRefusal(for target: TransferTarget) -> Bool {
        guard let last = lastRefusal, last.offer.target == target, now().timeIntervalSince(last.at) < 120 else { return false }
        lastRefusal = nil
        offer = last.offer
        return true
    }

    public enum RetryPrep: Sendable, Equatable {
        case offer(RoomOffer)
        /// It fits now: retried straight away.
        case retried
        case failed(String)
    }

    /// For a transfer that failed for lack of space: the offer to make room and retry, or a retry when it fits now.
    public func prepareRetry(_ item: TrackedTransfer) async -> RetryPrep {
        guard let putio else { return .failed("Sign in to put.io first.") }
        guard let size = item.transfer?.size, size > 0 else {
            return .failed("put.io ran out of space for this download. Free up some space, then try again.")
        }
        guard let avail = try? await putio.accountInfo().disk?.avail else { return .failed("Couldn't reach put.io. Try again.") }
        let target = TransferTarget(tmdbID: item.pending.tmdbID, kind: item.pending.kind, title: item.pending.title,
                                    posterPath: item.pending.posterPath, backdropPath: item.pending.backdropPath,
                                    season: item.pending.season, episode: item.pending.episode)
        guard let shortfall = SpaceCheck.shortfall(size: size, avail: avail) else {
            do {
                try await perform(.retry(transferID: item.id))
                return .retried
            } catch {
                return .failed("Couldn't retry it on put.io. Try again.")
            }
        }
        let plan = isEnabled ? await plan(needed: shortfall, target: target) : nil
        return .offer(RoomOffer(title: RoomOffer.title(for: target), size: size, avail: avail, plan: plan,
                                action: .retry(transferID: item.id), target: target))
    }

    /// What could go to free `needed` bytes, from the library as last read (read first if it never was).
    func plan(needed: Int64, target: TransferTarget?) async -> RoomPlan {
        guard let library else { return RoomPlan(needed: needed, candidates: []) }
        if library.folderTree.isEmpty { await library.refresh() }
        let state = await store.snapshot
        let entries = library.entries
        var positions: [Int64: Int] = [:]
        for entry in entries { positions[entry.id] = library.resumeSeconds(for: entry) }
        let rules = RoomPlanner.Rules(watched: Set(entries.filter { library.isWatched($0) }.map(\.id)),
                                      positions: positions, myList: Set(state.myList.map(\.id)), target: target,
                                      busyFolders: busyFolders())
        return RoomPlanner.plan(needed: needed, entries: entries, folders: Array(library.folderTree.folders.values), rules: rules)
    }

    /// The confirmation's working state for `offer`.
    public func session(for offer: RoomOffer) -> RoomSession {
        RoomSession(offer: offer, putio: putio, library: library, store: store, perform: perform)
    }
}
