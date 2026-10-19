import AMDBCore
import Foundation
import os

/// What the merge of the old AMDB folders did this time.
public struct OldFolderMergeReport: Sendable, Equatable {
    /// Movies and shows that left AMDB/Movies and AMDB/TV.
    public var movies = 0
    public var shows = 0
    /// Of the items that moved, how many got "(from AMDB)" in their name because the name was taken.
    public var renamed = 0
    /// Other things in AMDB, left where they are.
    public var leftInAMDB: [String] = []
    /// A rename or move failed. What moved stays moved; the rest is tried again at the next launch.
    public var couldNotMove = false
    /// Something in put.io changed (the library should be read again).
    public var changedPutio = false
    /// Nothing is left to merge: the old Movies and TV folders are gone (or never existed). Until then the merge runs
    /// again at each launch.
    public var finished = false
    /// The old AMDB/Movies and AMDB/TV folders (a Settings pick that is one of them goes back to the default).
    public var oldFolderIDs: Set<Int64> = []

    public init() {}

    /// What the user is told, or nil when there's nothing worth saying.
    public var message: String? {
        var sentences: [String] = []
        if movies + shows > 0 {
            let what = [movies > 0 ? Self.count(movies, "movie") : nil, shows > 0 ? Self.count(shows, "show") : nil]
            let into = [movies > 0 ? DefaultFolders.movies : nil, shows > 0 ? DefaultFolders.tv : nil]
            sentences.append("Moved \(what.compactMap { $0 }.joined(separator: " and ")) from AMDB into \(into.compactMap { $0 }.joined(separator: " and ")).")
            if renamed > 0 {
                sentences.append(renamed == 1 ? "One had the same name as something already there, so it now ends in “(from AMDB)”."
                                              : "\(renamed) had the same name as something already there, so they now end in “(from AMDB)”.")
            }
        }
        if couldNotMove { sentences.append("Some things in AMDB couldn't be moved yet. The app will try again next time.") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// Moves what older builds saved in AMDB/Movies and AMDB/TV into Movies and TV Series at the top of put.io (see
/// `FolderMergePlanner` for the rules). Safe to run any number of times, on several devices at once: it lists
/// put.io afresh, never overwrites or deletes a file, treats work another device already did as done, and stops at
/// the first rename or move that fails (the rest waits for the next run).
public enum OldFolderMerge {
    static let log = Logger(subsystem: "app.amdb", category: "folder-merge")
    /// put.io answers at most this many items per folder listing (`PutioClient.listFiles`).
    static let listingLimit = 1000
    /// More listings than this means something is wrong (a huge or looping tree): give up quietly.
    static let maxListings = 3000

    struct TooManyListings: Error {}

    public static func run(putio: any PutioService) async -> OldFolderMergeReport {
        var report = OldFolderMergeReport()
        do {
            try await merge(putio: putio, report: &report)
        } catch {
            // Offline, signed out, put.io busy: nothing to say; the next launch tries again.
            log.error("Folder merge stopped: \(String(describing: error), privacy: .public)")
        }
        return report
    }

    private static func merge(putio: any PutioService, report: inout OldFolderMergeReport) async throws {
        var lister = Lister(putio: putio)
        let root = try await lister.list(0)
        guard let old = DefaultFolders.folder(named: DefaultFolders.oldRoot, in: root) else {
            report.finished = true
            return
        }
        let oldChildren = try await lister.list(old.id)
        let movieSource = DefaultFolders.folder(named: DefaultFolders.oldMovies, in: oldChildren)
        let tvSource = DefaultFolders.folder(named: DefaultFolders.oldTV, in: oldChildren)
        report.oldFolderIDs = Set([movieSource?.id, tvSource?.id].compactMap { $0 })

        // Each source and what it merges into (created when missing), listed as deep as the merge needs.
        var pairs: [Int64: (source: PutioNode, target: PutioNode)] = [:]
        for (source, targetName) in [(movieSource, DefaultFolders.movies), (tvSource, DefaultFolders.tv)] {
            guard let source else { continue }
            let target = try await targetFolder(named: targetName, root: root, putio: putio)
            if let pair = try await loadPair(source, target, lister: &lister) {
                pairs[source.id] = pair
            } else {
                // A folder with more than put.io lists at once: its names can't all be checked, so don't merge into it.
                log.error("Not merging \(source.name, privacy: .public): \(targetName, privacy: .public) is too big to check for name clashes")
                report.couldNotMove = true
            }
        }
        let oldNode = PutioNode(old, children: oldChildren.map { pairs[$0.id]?.source ?? PutioNode($0) })
        let plan = FolderMergePlanner.planOldFolders(oldRoot: oldNode, movies: movieSource.flatMap { pairs[$0.id]?.target },
                                                     tv: tvSource.flatMap { pairs[$0.id]?.target })
        report.leftInAMDB = plan.leftAlone.filter { name in ![movieSource, tvSource].contains { $0?.name == name } }
        if !report.leftInAMDB.isEmpty {
            let left = report.leftInAMDB.joined(separator: ", ")
            log.info("Left in AMDB: \(left, privacy: .public)")
        }

        // A folder an unfinished transfer saves into stays, even when empty (the download lands there later).
        let busy = Set(((try? await putio.transfers()) ?? []).filter { transfer in
            switch TransferPhase(transfer) {
            case .queued, .downloading, .finishing: true
            case .completed, .failed: false
            }
        }.compactMap(\.saveParentId))

        let completed = await execute(plan.steps, busy: busy, putio: putio, report: &report)
        report.movies = await movedCount(plan.movieIDs, from: movieSource, putio: putio)
        report.shows = await movedCount(plan.showIDs, from: tvSource, putio: putio)
        if completed, !report.couldNotMove { report.finished = (try? await oldSourcesGone(old: old, putio: putio)) == true }
    }

    /// Runs the steps in order. Returns false when it stopped early.
    private static func execute(_ steps: [MergeStep], busy: Set<Int64>, putio: any PutioService,
                                report: inout OldFolderMergeReport) async -> Bool {
        for step in steps {
            switch step {
            case let .rename(id, parent, name):
                do {
                    try await putio.renameFile(id: id, name: name)
                    report.renamed += 1
                    report.changedPutio = true
                } catch {
                    // Gone from there, or already renamed (another device got to it first): done.
                    guard let here = try? await putio.listFiles(parentID: parent).files else { return stop(step, error, &report) }
                    if let item = here.first(where: { $0.id == id }), item.name != name { return stop(step, error, &report) }
                }
            case let .move(ids, from, into):
                do {
                    try await putio.moveFiles(ids: ids, to: into)
                    report.changedPutio = true
                } catch {
                    // Items no longer in `from` were moved already (another device); the rest get one more try.
                    guard let still = try? await putio.listFiles(parentID: from).files.map(\.id) else { return stop(step, error, &report) }
                    let left = ids.filter(still.contains)
                    guard !left.isEmpty else { continue }
                    do {
                        try await putio.moveFiles(ids: left, to: into)
                        report.changedPutio = true
                    } catch {
                        return stop(step, error, &report)
                    }
                }
            case let .deleteIfEmpty(id, name):
                if busy.contains(id) {
                    log.info("Kept \(name, privacy: .public): a transfer still saves there")
                    continue
                }
                // Listed right before deleting: only an empty folder goes (to put.io's Trash, where it can be restored).
                guard let contents = try? await putio.listFiles(parentID: id).files else { continue }
                guard contents.isEmpty else {
                    log.info("Kept \(name, privacy: .public): not empty")
                    continue
                }
                do {
                    try await putio.deleteFiles(ids: [id])
                    report.changedPutio = true
                } catch {
                    log.error("Couldn't delete \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        return true
    }

    private static func stop(_ step: MergeStep, _ error: any Error, _ report: inout OldFolderMergeReport) -> Bool {
        log.error("Folder merge step failed (\(String(describing: step), privacy: .public)): \(String(describing: error), privacy: .public)")
        report.couldNotMove = true
        return false
    }

    /// The folder called `name` at the top of put.io, created when missing. When two devices create it at the same
    /// moment, both settle on the oldest (lowest id), so their merges end up in one place.
    private static func targetFolder(named name: String, root: [PutioFile], putio: any PutioService) async throws -> PutioFile {
        if let existing = DefaultFolders.folder(named: name, in: root) { return existing }
        let created = try await putio.createFolder(name: name, parentID: 0)
        let now = try await putio.listFiles(parentID: 0).files
        let same = now.filter { $0.isFolder && DefaultFolders.sameName($0.name, name) }
        return same.min { $0.id < $1.id } ?? created
    }

    /// Lists `source` and `target`, and below them every pair of folders with the same name (the ones that merge).
    /// nil when a target folder is too full to list at once.
    private static func loadPair(_ source: PutioFile, _ target: PutioFile,
                                 lister: inout Lister) async throws -> (source: PutioNode, target: PutioNode)? {
        let sourceChildren = try await lister.list(source.id)
        let targetChildren = try await lister.list(target.id)
        guard targetChildren.count < listingLimit else { return nil }
        var sourceNodes: [PutioNode] = []
        var targetNodes = targetChildren.map { PutioNode($0) }
        for child in sourceChildren {
            guard child.isFolder,
                  let index = targetNodes.firstIndex(where: { $0.file.isFolder && $0.id != child.id && DefaultFolders.sameName($0.name, child.name) })
            else {
                sourceNodes.append(PutioNode(child))
                continue
            }
            guard let pair = try await loadPair(child, targetNodes[index].file, lister: &lister) else { return nil }
            sourceNodes.append(pair.source)
            targetNodes[index] = pair.target
        }
        return (PutioNode(source, children: sourceNodes), PutioNode(target, children: targetNodes))
    }

    /// How many of `ids` are no longer in `source` (all of them when the folder itself is gone).
    private static func movedCount(_ ids: [Int64], from source: PutioFile?, putio: any PutioService) async -> Int {
        guard let source, !ids.isEmpty else { return 0 }
        do {
            let still = Set(try await putio.listFiles(parentID: source.id).files.map(\.id))
            return ids.filter { !still.contains($0) }.count
        } catch AppError.http(_, 404) {
            return ids.count
        } catch {
            return 0
        }
    }

    /// Whether AMDB no longer holds a Movies or TV folder.
    private static func oldSourcesGone(old: PutioFile, putio: any PutioService) async throws -> Bool {
        let children: [PutioFile]
        do {
            children = try await putio.listFiles(parentID: old.id).files
        } catch AppError.http(_, 404) {
            return true
        }
        return DefaultFolders.folder(named: DefaultFolders.oldMovies, in: children) == nil
            && DefaultFolders.folder(named: DefaultFolders.oldTV, in: children) == nil
    }

    /// Counts listings so a merge can never run away.
    struct Lister {
        let putio: any PutioService
        var count = 0

        mutating func list(_ id: Int64) async throws -> [PutioFile] {
            count += 1
            guard count <= OldFolderMerge.maxListings else { throw TooManyListings() }
            return try await putio.listFiles(parentID: id).files
        }
    }
}
