import AMDBCore
import Foundation

/// A put.io file or folder with as much of its contents as a merge needs (a folder that moves whole isn't listed).
public struct PutioNode: Sendable, Equatable {
    public let file: PutioFile
    public var children: [PutioNode]

    public init(_ file: PutioFile, children: [PutioNode] = []) { self.file = file; self.children = children }

    public var id: Int64 { file.id }
    public var name: String { file.name }
}

/// One change to put.io. Steps run in order, and each is safe to run again (see `OldFolderMerge`).
public enum MergeStep: Sendable, Equatable {
    /// Gives an item a new name where it is, before it moves next to something with the same name.
    case rename(id: Int64, in: Int64, to: String)
    /// Moves items out of one folder into another (one put.io call).
    case move(ids: [Int64], from: Int64, into: Int64)
    /// Deletes a folder the moves emptied (into put.io's Trash). Skipped unless it's empty when the step runs.
    case deleteIfEmpty(id: Int64, name: String)
}

public struct MergePlan: Sendable, Equatable {
    public var steps: [MergeStep] = []
    /// Items that move under a new name because their name was taken.
    public var renamed = 0

    public init(steps: [MergeStep] = [], renamed: Int = 0) { self.steps = steps; self.renamed = renamed }
}

/// What to do with the old AMDB folder: AMDB/Movies merges into Movies and AMDB/TV into TV Series. Anything else in
/// AMDB stays where it is.
public struct OldFoldersPlan: Sendable, Equatable {
    public var steps: [MergeStep]
    public var renamed: Int
    /// The movies and shows that move (top-level items of AMDB/Movies and AMDB/TV that are folders or videos):
    /// afterwards, the ones no longer there are the ones that moved.
    public var movieIDs: [Int64]
    public var showIDs: [Int64]
    /// Names of other things in AMDB, left alone.
    public var leftAlone: [String]
}

/// Plans merging one folder into another without touching put.io, so every decision can be tested.
public enum FolderMergePlanner {
    /// Added to the name of an item that moves next to something with the same name: "Heat (from AMDB).mkv".
    public static let renameNote = "from AMDB"

    /// Merges `source` into `target`. Each item moves in, except a folder whose name (ignoring case and surrounding
    /// spaces) is already a folder there: that one merges the same way, so AMDB/TV/Severance/Season 2 joins
    /// TV Series/Severance/Season 2. An item whose name is taken by anything else moves under a new name; nothing is
    /// overwritten or deleted. Folders emptied by the merge are deleted last, deepest first (`source` only when
    /// `deleteSource`), and only if they turn out empty when it's their turn.
    public static func plan(source: PutioNode, into target: PutioNode, deleteSource: Bool = true) -> MergePlan {
        var plan = MergePlan()
        guard source.id != target.id else { return plan }
        merge(source, into: target, plan: &plan)
        if deleteSource { plan.steps.append(.deleteIfEmpty(id: source.id, name: source.name)) }
        return plan
    }

    /// The whole job: `oldRoot` is AMDB (its Movies and TV folders listed), `movies` and `tv` the folders they merge
    /// into (nil: that one isn't merged this time). AMDB itself goes once nothing else is in it.
    public static func planOldFolders(oldRoot: PutioNode, movies: PutioNode?, tv: PutioNode?) -> OldFoldersPlan {
        let movieSource = oldSource(DefaultFolders.oldMovies, in: oldRoot)
        let tvSource = oldSource(DefaultFolders.oldTV, in: oldRoot)
        var result = OldFoldersPlan(steps: [], renamed: 0, movieIDs: [], showIDs: [], leftAlone: [])
        var merged: Set<Int64> = []
        if let source = movieSource, let movies {
            let plan = plan(source: source, into: movies)
            result.steps += plan.steps
            result.renamed += plan.renamed
            result.movieIDs = countable(source)
            merged.insert(source.id)
        }
        if let source = tvSource, let tv {
            let plan = plan(source: source, into: tv)
            result.steps += plan.steps
            result.renamed += plan.renamed
            result.showIDs = countable(source)
            merged.insert(source.id)
        }
        result.leftAlone = oldRoot.children.filter { !merged.contains($0.id) }.map(\.name).sorted()
        if result.leftAlone.isEmpty { result.steps.append(.deleteIfEmpty(id: oldRoot.id, name: oldRoot.name)) }
        return result
    }

    /// AMDB's "Movies" or "TV" folder (the exact spelling first, else ignoring case).
    static func oldSource(_ name: String, in oldRoot: PutioNode) -> PutioNode? {
        guard let file = DefaultFolders.folder(named: name, in: oldRoot.children.map(\.file)) else { return nil }
        return oldRoot.children.first { $0.id == file.id }
    }

    private static func countable(_ source: PutioNode) -> [Int64] {
        source.children.filter { $0.file.isFolder || $0.file.isVideo }.map(\.id)
    }

    private static func merge(_ source: PutioNode, into target: PutioNode, plan: inout MergePlan) {
        let targetIDs = Set(target.children.map(\.id))
        var taken = Set(target.children.map { DefaultFolders.key($0.name) })
        // A new name mustn't match anything still in the source either: that moves in too.
        let sourceNames = Set(source.children.map { DefaultFolders.key($0.name) })
        var renames: [MergeStep] = []
        var moves: [Int64] = []
        var nested: [(source: PutioNode, target: PutioNode)] = []
        for child in source.children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            // Listed in both (another device moved it while this one was looking): already done.
            if targetIDs.contains(child.id) { continue }
            let key = DefaultFolders.key(child.name)
            guard let existing = target.children.first(where: { DefaultFolders.key($0.name) == key }) else {
                moves.append(child.id)
                taken.insert(key)
                continue
            }
            if child.file.isFolder, existing.file.isFolder {
                nested.append((child, existing))
                continue
            }
            let name = freeName(for: child, taken: taken.union(sourceNames))
            taken.insert(DefaultFolders.key(name))
            renames.append(.rename(id: child.id, in: source.id, to: name))
            moves.append(child.id)
            plan.renamed += 1
        }
        plan.steps += renames
        if !moves.isEmpty { plan.steps.append(.move(ids: moves, from: source.id, into: target.id)) }
        for pair in nested where pair.source.id != pair.target.id {
            merge(pair.source, into: pair.target, plan: &plan)
            plan.steps.append(.deleteIfEmpty(id: pair.source.id, name: pair.source.name))
        }
    }

    /// "Heat.1995.mkv" → "Heat.1995 (from AMDB).mkv", then "(from AMDB 2)" and so on until the name is free.
    static func freeName(for node: PutioNode, taken: Set<String>) -> String {
        let (base, ext) = split(node.name, isFolder: node.file.isFolder)
        for attempt in 1...999 {
            let note = attempt == 1 ? renameNote : "\(renameNote) \(attempt)"
            let candidate = "\(base) (\(note))" + (ext.isEmpty ? "" : ".\(ext)")
            if !taken.contains(DefaultFolders.key(candidate)) { return candidate }
        }
        return "\(base) (\(renameNote) \(node.id))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// A file's extension is the short tail after the last dot ("mkv", "srt"); folders and names like
    /// "Show.S02E04" or "Movie.2024" have none.
    private static func split(_ name: String, isFolder: Bool) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !isFolder, (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }),
              ext.contains(where: \.isLetter) else {
            return (name.trimmingCharacters(in: .whitespaces), "")
        }
        return (String(name.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces), ext)
    }
}
