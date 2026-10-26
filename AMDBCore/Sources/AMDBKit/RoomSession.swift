import AMDBCore
import Foundation
import Observation

/// One make-room confirmation: the user ticks what may go, then `confirm` deletes exactly that. put.io keeps deleted
/// files in its Trash for a while; when the free space didn't grow enough, `phase` asks before removing exactly those
/// items from the Trash (`purgeTrash`). The whole Trash is never emptied.
@Observable @MainActor
public final class RoomSession: Identifiable {
    public enum Phase: Sendable, Equatable {
        case choosing
        case working(String)
        /// Deleted, but put.io still counts them: these Trash items may be removed for good.
        case trash([PutioTrashFile])
        /// Room made and the download sent: "Freed 9.8 GB · Getting Dune: Part Two".
        case done(String)
        case failed(String)
    }

    public let offer: RoomOffer
    public var selection: Set<Int64>
    public private(set) var phase: Phase = .choosing
    /// What was deleted (in put.io's Trash or gone).
    public private(set) var deleted: [RoomCandidate] = []

    @ObservationIgnored private let putio: (any PutioService)?
    @ObservationIgnored private weak var library: LibraryIndex?
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let perform: @MainActor (RoomAction) async throws -> Void
    /// Ids per put.io delete call.
    static let batchSize = 20

    init(offer: RoomOffer, putio: (any PutioService)?, library: LibraryIndex?, store: LocalStore,
         perform: @escaping @MainActor (RoomAction) async throws -> Void) {
        self.offer = offer
        self.putio = putio
        self.library = library
        self.store = store
        self.perform = perform
        selection = offer.plan?.suggested ?? []
    }

    public nonisolated var id: UUID { offer.id }
    public var candidates: [RoomCandidate] { offer.plan?.candidates ?? [] }
    public var freed: Int64 { offer.plan?.freed(selection) ?? 0 }
    /// The ticked items free enough.
    public var isEnough: Bool { !selection.isEmpty && freed >= offer.needed }
    public var canDelete: Bool { phase == .choosing && offer.canMakeRoom && isEnough }

    public func toggle(_ id: Int64) {
        guard phase == .choosing else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// Deletes exactly the ticked items (after checking each folder still holds only what the library knew), then
    /// gets the download once put.io has the room.
    public func confirm() async {
        guard canDelete, let putio, let plan = offer.plan else { return }
        let chosen = plan.chosen(selection)
        phase = .working("Checking…")
        for candidate in chosen where candidate.isFolder {
            guard await Self.holdsOnly(candidate, putio: putio) else {
                phase = .failed("\u{201C}\(candidate.name)\u{201D} changed since the library was last read. Nothing was deleted. "
                                + "Update the library and try again.")
                return
            }
        }
        phase = .working("Deleting…")
        for start in stride(from: 0, to: chosen.count, by: Self.batchSize) {
            let batch = Array(chosen[start..<min(start + Self.batchSize, chosen.count)])
            do {
                try await putio.deleteFiles(ids: batch.map(\.id))
                deleted += batch
            } catch {
                await forgetDeleted()
                phase = .failed("put.io stopped answering after \(deleted.count) of \(chosen.count) deletions. "
                                + "\(offer.title) wasn't sent.")
                return
            }
        }
        await forgetDeleted()
        await proceed(trashPurged: false)
    }

    /// Removes the deleted items from put.io's Trash for good (only those), then gets the download.
    public func purgeTrash() async {
        guard case let .trash(items) = phase, let putio else { return }
        let deletedIDs = Set(deleted.map(\.id))
        let ids = items.map(\.id).filter(deletedIDs.contains)
        phase = .working("Deleting from Trash…")
        for start in stride(from: 0, to: ids.count, by: Self.batchSize) {
            do {
                try await putio.deleteFromTrash(ids: Array(ids[start..<min(start + Self.batchSize, ids.count)]))
            } catch {
                phase = .failed("Couldn't delete them from put.io's Trash. \(offer.title) wasn't sent.")
                return
            }
        }
        await proceed(trashPurged: true)
    }

    /// Leaves them in put.io's Trash (put.io empties it after a while); the download isn't sent.
    public func keepInTrash() {
        guard case .trash = phase else { return }
        phase = .failed("They're in put.io's Trash, and put.io still counts them, so \(offer.title) wasn't sent. "
                        + "You can restore them from Library → Files → Trash.")
    }

    private func proceed(trashPurged: Bool) async {
        guard let putio else { return }
        phase = .working("Checking free space…")
        let avail = try? await putio.accountInfo().disk?.avail
        // put.io not answering: let the download try (put.io decides).
        if avail.map({ $0 >= offer.required }) ?? true {
            await run()
            return
        }
        if !trashPurged {
            let deletedIDs = Set(deleted.map(\.id))
            let inTrash = ((try? await putio.trash())?.files ?? []).filter { deletedIDs.contains($0.id) }
            if !inTrash.isEmpty {
                phase = .trash(inTrash)
                return
            }
        }
        phase = .failed("Deleted \(RoomFormat.bytes(freedSoFar)), but put.io still shows only "
                        + "\(RoomFormat.bytes(avail ?? 0)) free, so \(offer.title) wasn't sent. Try again in a few minutes.")
    }

    private var freedSoFar: Int64 { deleted.reduce(0) { $0 + $1.size } }

    private func run() async {
        phase = .working("Sending to put.io…")
        do {
            try await perform(offer.action)
            phase = .done("Freed \(RoomFormat.bytes(freedSoFar)) · Getting \(offer.title)")
        } catch {
            phase = .failed("Made room, but couldn't send \(offer.title) to put.io. Try Get again.")
        }
    }

    /// The library drops what went, and folder ids remembered for saving are looked up again (one may be gone).
    private func forgetDeleted() async {
        guard !deleted.isEmpty else { return }
        await library?.forget(Set(deleted.flatMap(\.fileIDs)))
        await FolderResolver.forgetAll(store: store)
    }

    /// Whether every video in the folder (at any depth) is one the plan counted. A folder put.io can't list fails.
    static func holdsOnly(_ candidate: RoomCandidate, putio: any PutioService) async -> Bool {
        let known = Set(candidate.fileIDs)
        var queue = [candidate.id]
        var listed = 0
        while let folder = queue.popLast() {
            listed += 1
            guard listed <= 200, let files = try? await putio.listFiles(parentID: folder).files else { return false }
            for file in files {
                if file.isFolder {
                    if !LibraryIndex.isSkippedFolder(file.name) { queue.append(file.id) }
                } else if file.isVideo, !LibraryIndex.isSample(file), !known.contains(file.id) {
                    return false
                }
            }
        }
        return true
    }
}
