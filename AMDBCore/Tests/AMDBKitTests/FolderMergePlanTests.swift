import AMDBCore
import Testing
@testable import AMDBKit

/// The merge planner on its own: two folder trees in, a list of steps out.
@Suite struct FolderMergePlanTests {
    static func folder(_ id: Int64, _ name: String, _ children: [PutioNode] = []) -> PutioNode {
        PutioNode(PutioFile(id: id, name: name, fileType: "FOLDER"), children: children)
    }

    static func video(_ id: Int64, _ name: String) -> PutioNode {
        PutioNode(PutioFile(id: id, name: name, fileType: "VIDEO"))
    }

    static func file(_ id: Int64, _ name: String) -> PutioNode {
        PutioNode(PutioFile(id: id, name: name, fileType: "TEXT"))
    }

    @Test func emptySourceIsOnlyDeleted() {
        let plan = FolderMergePlanner.plan(source: Self.folder(1, "Movies"), into: Self.folder(2, "Movies"))
        #expect(plan.steps == [.deleteIfEmpty(id: 1, name: "Movies")])
        #expect(plan.renamed == 0)
    }

    @Test func itemsMoveInOneBatch() {
        let source = Self.folder(1, "Movies", [Self.folder(11, "Dune.Part.Two.2024.1080p"), Self.video(12, "Heat.1995.mkv"),
                                               Self.folder(13, "Arrival (2016)")])
        let target = Self.folder(2, "Movies", [Self.folder(21, "Past Lives")])
        let plan = FolderMergePlanner.plan(source: source, into: target)
        #expect(plan.steps == [.move(ids: [13, 11, 12], from: 1, into: 2), .deleteIfEmpty(id: 1, name: "Movies")])
    }

    /// AMDB/TV/Severance/Season 2 joins TV Series/severance/Season 2; Andor moves whole; emptied folders go last,
    /// deepest first.
    @Test func sameNamedShowsAndSeasonsMerge() {
        let source = Self.folder(1, "TV", [
            Self.folder(10, "Severance", [Self.folder(11, "Season 2", [Self.video(111, "Severance.S02E04.mkv")]),
                                          Self.folder(12, "Season 3", [Self.video(121, "Severance.S03E01.mkv")])]),
            Self.folder(20, "Andor", [Self.folder(21, "Season 1")]),
        ])
        let target = Self.folder(2, "TV Series", [
            Self.folder(30, " severance", [Self.folder(31, "season 2", [Self.video(311, "Severance.S02E01.mkv")])]),
        ])
        let plan = FolderMergePlanner.plan(source: source, into: target)
        #expect(plan.steps == [
            .move(ids: [20], from: 1, into: 2),
            .move(ids: [12], from: 10, into: 30),
            .move(ids: [111], from: 11, into: 31),
            .deleteIfEmpty(id: 11, name: "Season 2"),
            .deleteIfEmpty(id: 10, name: "Severance"),
            .deleteIfEmpty(id: 1, name: "TV"),
        ])
    }

    /// A taken name never overwrites: the item moves under a new one, and that one is checked too.
    @Test func nameClashesAreRenamedNotOverwritten() {
        let source = Self.folder(1, "Movies", [Self.video(11, "Heat.1995.mkv"), Self.folder(12, "Dune"),
                                               Self.file(13, "notes"), Self.video(14, "Heat.1995 (from AMDB 2).mkv")])
        let target = Self.folder(2, "Movies", [Self.video(21, "heat.1995.MKV"), Self.video(22, "Heat.1995 (from AMDB).mkv"),
                                               Self.video(23, "Dune"), Self.folder(24, "Notes")])
        let plan = FolderMergePlanner.plan(source: source, into: target)
        #expect(plan.steps == [
            .rename(id: 12, in: 1, to: "Dune (from AMDB)"),
            .rename(id: 11, in: 1, to: "Heat.1995 (from AMDB 3).mkv"),
            .rename(id: 13, in: 1, to: "notes (from AMDB)"),
            .move(ids: [12, 14, 11, 13], from: 1, into: 2),
            .deleteIfEmpty(id: 1, name: "Movies"),
        ])
        #expect(plan.renamed == 3)
    }

    @Test func newNamesKeepTheExtension() {
        let taken: Set<String> = []
        #expect(FolderMergePlanner.freeName(for: Self.video(1, "Show.S02E04.1080p.mkv"), taken: taken) == "Show.S02E04.1080p (from AMDB).mkv")
        #expect(FolderMergePlanner.freeName(for: Self.video(2, "Show.S02E04"), taken: taken) == "Show.S02E04 (from AMDB)")
        #expect(FolderMergePlanner.freeName(for: Self.video(3, "Movie.2024"), taken: taken) == "Movie.2024 (from AMDB)")
        #expect(FolderMergePlanner.freeName(for: Self.folder(4, "Release.1080p.WEB"), taken: taken) == "Release.1080p.WEB (from AMDB)")
    }

    /// Run again after everything moved (or by another device meanwhile): nothing moves twice.
    @Test func alreadyMergedIsANoOp() {
        let moved = Self.video(11, "Heat.1995.mkv")
        let source = Self.folder(1, "Movies", [moved])
        let target = Self.folder(2, "Movies", [moved])
        #expect(FolderMergePlanner.plan(source: source, into: target).steps == [.deleteIfEmpty(id: 1, name: "Movies")])
        #expect(FolderMergePlanner.plan(source: source, into: source).steps.isEmpty, "a folder never merges into itself")
        let show = Self.folder(10, "Severance", [Self.folder(11, "Season 2")])
        let plan = FolderMergePlanner.plan(source: Self.folder(1, "TV", [show]), into: Self.folder(2, "TV Series", [show]))
        #expect(plan.steps == [.deleteIfEmpty(id: 1, name: "TV")])
    }

    /// Only AMDB/Movies and AMDB/TV merge; anything else in AMDB stays, and so does AMDB.
    @Test func otherThingsInAMDBAreLeftAlone() {
        let old = Self.folder(1, "AMDB", [
            Self.folder(2, "movies", [Self.folder(21, "Dune (2021)"), Self.video(22, "Heat.mkv"), Self.file(23, "notes.txt")]),
            Self.folder(3, "TV", [Self.folder(31, "Severance")]),
            Self.folder(4, "Music", [Self.file(41, "song.mp3")]),
            Self.file(5, "readme.txt"),
        ])
        let plan = FolderMergePlanner.planOldFolders(oldRoot: old, movies: Self.folder(100, "Movies"), tv: Self.folder(200, "TV Series"))
        #expect(plan.leftAlone == ["Music", "readme.txt"])
        #expect(plan.movieIDs == [21, 22], "a stray text file isn't a movie")
        #expect(plan.showIDs == [31])
        #expect(plan.steps == [
            .move(ids: [21, 22, 23], from: 2, into: 100), .deleteIfEmpty(id: 2, name: "movies"),
            .move(ids: [31], from: 3, into: 200), .deleteIfEmpty(id: 3, name: "TV"),
        ])
        #expect(!plan.steps.contains(.deleteIfEmpty(id: 1, name: "AMDB")))
    }

    /// AMDB itself goes only when Movies and TV were all that was in it, and only after them.
    @Test func amdbIsDeletedLastWhenNothingElseIsInIt() {
        let old = Self.folder(1, "AMDB", [Self.folder(2, "Movies", [Self.video(22, "Heat.mkv")])])
        let plan = FolderMergePlanner.planOldFolders(oldRoot: old, movies: Self.folder(100, "Movies"), tv: nil)
        #expect(plan.steps.last == .deleteIfEmpty(id: 1, name: "AMDB"))
        #expect(plan.leftAlone.isEmpty)

        // A source without a destination this time stays, and so does AMDB.
        let withTV = Self.folder(1, "AMDB", [Self.folder(2, "Movies"), Self.folder(3, "TV", [Self.folder(31, "Severance")])])
        let partial = FolderMergePlanner.planOldFolders(oldRoot: withTV, movies: Self.folder(100, "Movies"), tv: nil)
        #expect(partial.leftAlone == ["TV"])
        #expect(partial.steps == [.deleteIfEmpty(id: 2, name: "Movies")])
    }

    @Test func noOldFoldersNoSteps() {
        let plan = FolderMergePlanner.planOldFolders(oldRoot: Self.folder(1, "AMDB", [Self.folder(4, "Music")]), movies: nil, tv: nil)
        #expect(plan.steps.isEmpty)
        #expect(plan.leftAlone == ["Music"])
    }
}
