import AMDBCore
import Foundation

/// Fix Match: the user picks the title (and for shows, optionally the season) for files automatic matching got
/// wrong or couldn't find. Choices are kept in `LocalState.matchOverrides` and win over automatic matching on every
/// update, until Match Automatically.
extension LibraryIndex {
    /// The Fix Match choice behind a file's match, if any.
    public func override(for file: PutioFile) -> MatchOverride? {
        overrides.override(for: file, folderIDs: folderTree.chain(from: file.parentId))
    }

    /// Whether Match Automatically has anything to undo for these files (or this folder).
    public func hasOverride(_ files: [PutioFile], folderID: Int64? = nil) -> Bool {
        folderID.map { overrides.folders[$0] != nil } == true || files.contains { override(for: $0) != nil }
    }

    /// Saves the choice for `target`, then shows it at once on every library file it covers.
    public func fixMatch(_ target: FixMatchTarget, as chosen: MatchOverride) async {
        await store.update { state in
            switch target {
            case let .files(files):
                for file in files { state.matchOverrides.files[file.id] = chosen }
            case let .folder(id, _):
                state.matchOverrides.folders[id] = chosen
            case let .sameName(name):
                if let key = MatchOverrides.nameKey(name) { state.matchOverrides.names[key] = chosen }
            }
        }
        overrides = await store.snapshot.matchOverrides
        var changes: [Int64: LibraryMatch?] = [:]
        for entry in entries {
            if let applied = override(for: entry.file) { changes[entry.id] = applied.match(fileName: entry.file.name) }
        }
        await setMatches(changes)
    }

    /// Match Automatically: forgets every choice covering these files (their own, any folder above them, their name)
    /// and the folder's own, then looks up every file that loses its choice like a new one. Returns how many files
    /// went back to automatic matching.
    @discardableResult
    public func matchAutomatically(_ files: [PutioFile], folderID: Int64? = nil) async -> Int {
        let before = entries.filter { override(for: $0.file) != nil }
        let folderIDs = Set(files.flatMap { folderTree.chain(from: $0.parentId) } + (folderID.map { [$0] } ?? []))
        let fileIDs = Set(files.map(\.id))
        let names = Set(files.compactMap { MatchOverrides.nameKey($0.name) })
        await store.update { state in
            for id in fileIDs { state.matchOverrides.files[id] = nil }
            for id in folderIDs { state.matchOverrides.folders[id] = nil }
            for key in names { state.matchOverrides.names[key] = nil }
        }
        overrides = await store.snapshot.matchOverrides
        let released = before.filter { override(for: $0.file) == nil }
        let ids = Set(released.map(\.id))
        // Their old automatic verdicts are what Fix Match was correcting: look them up again.
        await store.update { state in
            for id in ids {
                state.matches[id] = nil
                state.unmatched.remove(id)
                state.unmatchedAt[id] = nil
            }
        }
        var changes: [Int64: LibraryMatch?] = [:]
        for entry in released {
            changes[entry.id] = .some(nil)
            guard let matcher else { continue }
            if case let .matched(match) = await Self.matchOutcome(entry, matcher) {
                changes[entry.id] = match
                await store.update { $0.matches[entry.id] = match }
            }
        }
        await setMatches(changes)
        return released.count
    }
}
