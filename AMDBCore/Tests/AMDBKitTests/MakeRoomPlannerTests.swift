import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// A put.io library for the make-room rules (sizes in bytes, kept small).
///
///     Movies/                      (10)
///       Old Movie (2001)/old.mkv   (11 / 111)  movie 1, watched, 4000, added 2026-01-01
///       loose.mkv                  (12)        movie 2, 1500, added 2026-02-01
///       Watching (2020)/w.mkv      (13 / 131)  movie 3, at 10 minutes
///       Listed/l.mkv               (14 / 141)  movie 4, on My List
///       Collection/a.mkv, b.mkv    (15 / 151, 152)  movies 5 and 6 in one folder
///     TV Series/                   (20)
///       Show/                      (21)
///         Season 1/ e1, e2         (22 / 221, 222)  show 100 S1, watched
///         Season 2/ e1             (23 / 231)       show 100 S2, watched
///         S03E01.mkv, S03E02.mkv   (211, 212)       show 100 S3, loose in the show folder
///     Other/other.mkv              (30 / 301)  not Movies or TV Series
///     top.mkv                      (5)         loose at the top of put.io
enum RoomFixture {
    static func folder(_ id: Int64, _ name: String, parent: Int64, size: Int64? = nil, added: String = "2025-01-01T00:00:00") -> PutioFile {
        PutioFile(id: id, name: name, fileType: "FOLDER", size: size, parentId: parent, createdAt: added)
    }

    static func video(_ id: Int64, _ name: String, parent: Int64, size: Int64?, added: String) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "VIDEO", size: size, parentId: parent, createdAt: added)
    }

    static func movie(_ id: Int) -> LibraryMatch {
        LibraryMatch(tmdbID: id, mediaType: .movie, season: nil, episode: nil, confidence: 1, title: "Movie \(id)", posterPath: "/m\(id).jpg",
                     backdropPath: nil)
    }

    static func episode(_ season: Int, _ episode: Int) -> LibraryMatch {
        LibraryMatch(tmdbID: 100, mediaType: .tv, season: season, episode: episode, confidence: 1, title: "Show", posterPath: "/show.jpg",
                     backdropPath: nil)
    }

    static let folders: [PutioFile] = [
        folder(10, "movies", parent: 0),
        folder(11, "Old Movie (2001)", parent: 10, size: 4100, added: "2026-01-01T00:00:00"),
        folder(13, "Watching (2020)", parent: 10, size: 3000, added: "2025-12-01T00:00:00"),
        folder(14, "Listed", parent: 10, size: 2000, added: "2025-11-01T00:00:00"),
        folder(15, "Collection", parent: 10, size: 2000, added: "2025-10-01T00:00:00"),
        folder(20, " TV Series ", parent: 0),
        folder(21, "Show", parent: 20, size: 10_500, added: "2025-06-01T00:00:00"),
        folder(22, "Season 1", parent: 21, size: 6000, added: "2025-06-01T00:00:00"),
        folder(23, "Season 2", parent: 21, size: 2500, added: "2025-07-01T00:00:00"),
        folder(30, "Other", parent: 0, size: 900),
    ]

    static let entries: [LibraryEntry] = [
        LibraryEntry(file: video(111, "old.mkv", parent: 11, size: 4000, added: "2026-01-01T00:00:00"), match: movie(1), folderName: nil),
        LibraryEntry(file: video(12, "loose.mkv", parent: 10, size: 1500, added: "2026-02-01T00:00:00"), match: movie(2), folderName: nil),
        LibraryEntry(file: video(131, "w.mkv", parent: 13, size: 3000, added: "2025-12-01T00:00:00"), match: movie(3), folderName: nil),
        LibraryEntry(file: video(141, "l.mkv", parent: 14, size: 2000, added: "2025-11-01T00:00:00"), match: movie(4), folderName: nil),
        LibraryEntry(file: video(151, "a.mkv", parent: 15, size: 1000, added: "2025-10-01T00:00:00"), match: movie(5), folderName: nil),
        LibraryEntry(file: video(152, "b.mkv", parent: 15, size: 1000, added: "2025-10-02T00:00:00"), match: movie(6), folderName: nil),
        LibraryEntry(file: video(221, "S01E01.mkv", parent: 22, size: 3000, added: "2025-06-01T00:00:00"), match: episode(1, 1), folderName: nil),
        LibraryEntry(file: video(222, "S01E02.mkv", parent: 22, size: 3000, added: "2025-06-01T00:00:00"), match: episode(1, 2), folderName: nil),
        LibraryEntry(file: video(231, "S02E01.mkv", parent: 23, size: 2500, added: "2025-07-01T00:00:00"), match: episode(2, 1), folderName: nil),
        LibraryEntry(file: video(211, "S03E01.mkv", parent: 21, size: 1000, added: "2025-08-01T00:00:00"), match: episode(3, 1), folderName: nil),
        LibraryEntry(file: video(212, "S03E02.mkv", parent: 21, size: 1000, added: "2025-08-02T00:00:00"), match: episode(3, 2), folderName: nil),
        LibraryEntry(file: video(301, "other.mkv", parent: 30, size: 900, added: "2020-01-01T00:00:00"), match: movie(7), folderName: nil),
        LibraryEntry(file: video(5, "top.mkv", parent: 0, size: 800, added: "2020-01-01T00:00:00"), match: movie(8), folderName: nil),
    ]

    static let rules = RoomPlanner.Rules(watched: [111, 221, 222, 231], positions: [131: 600], myList: ["movie-4"])
}

@Suite struct MakeRoomPlannerTests {
    @Test func spaceCheckAddsTwoPercent() {
        #expect(SpaceCheck.required(size: 1000) == 1020)
        #expect(SpaceCheck.shortfall(size: 1000, avail: 1020) == nil)
        #expect(SpaceCheck.shortfall(size: 1000, avail: 1019) == 1)
        #expect(SpaceCheck.shortfall(size: 1000, avail: 2000) == nil)
        #expect(SpaceCheck.shortfall(size: 7_400_000_000, avail: 2_100_000_000) == Int64(7_548_000_000 - 2_100_000_000))
    }

    @Test func unknownSizeOrFreeSpaceIsNeverChecked() {
        #expect(SpaceCheck.shortfall(size: nil, avail: 10) == nil)
        #expect(SpaceCheck.shortfall(size: 0, avail: 10) == nil)
        #expect(SpaceCheck.shortfall(size: 1000, avail: nil) == nil)
    }

    @Test func outOfSpaceErrorsAreRecognisedLeniently() {
        for message in ["Not enough disk space", "There is not enough space in your account.", "Insufficient storage",
                        "No space left on device", "Your disk is full", "Disk quota exceeded", "Storage full",
                        "out of space", "The download exceeds your available storage", "NOT ENOUGH SPACE"] {
            #expect(OutOfSpace.matches(message), "\(message)")
        }
        for message in [nil, "", "Tracker error", "No peers", "Invalid torrent", "put.io reported an error",
                        "Transfer limit reached", "Too many transfers", "Space Jam.mkv not found"] {
            #expect(!OutOfSpace.matches(message), "\(message ?? "nil")")
        }
    }

    @Test func watchedFirstThenUnwatchedOldestAddedFirst() {
        let ids = RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules).map(\.id)
        // Watched: Season 1 (Jun), Season 2 (Jul), Old Movie (Jan '26). Unwatched: S3 episodes (Aug), the two
        // movies sharing a folder (Oct), the loose movie (Feb '26).
        #expect(ids == [22, 23, 11, 211, 212, 151, 152, 12])
    }

    @Test func keepsWhatsBeingWatchedOnMyListAndOutsideMoviesAndTV() {
        let candidates = RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules)
        let ids = Set(candidates.flatMap { [$0.id] + $0.fileIDs })
        #expect(!ids.contains(13) && !ids.contains(131))   // at 10 minutes
        #expect(!ids.contains(14) && !ids.contains(141))   // My List
        #expect(!ids.contains(30) && !ids.contains(301))   // another top-level folder
        #expect(!ids.contains(5))                          // loose at the top of put.io
        #expect(!ids.contains(10) && !ids.contains(20) && !ids.contains(21))  // never Movies, TV Series or a mixed show folder
    }

    @Test func aFinishedVideoIsntInProgressAndAShortPeekIsnt() {
        var rules = RoomFixture.rules
        rules.positions = [131: 29]
        #expect(RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).contains { $0.id == 13 })
        rules.positions = [131: 30]
        #expect(!RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).contains { $0.id == 13 })
        // Watched to the end (the position put.io keeps doesn't matter then).
        rules.watched.insert(131)
        #expect(RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).contains { $0.id == 13 })
    }

    @Test func seasonFoldersGoWholeAndLooseEpisodesAlone() {
        let candidates = RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules)
        let season1 = candidates.first { $0.id == 22 }
        #expect(season1?.isFolder == true && season1?.kind == .season && season1?.season == 1 && season1?.episode == nil)
        #expect(season1?.fileIDs.sorted() == [221, 222])
        #expect(season1?.size == 6000)
        #expect(season1?.detail == "Season 1")
        #expect(season1?.watched == true)
        let episode = candidates.first { $0.id == 211 }
        #expect(episode?.isFolder == false && episode?.kind == .episode && episode?.detail == "S3 E1" && episode?.watched == false)
        // A movie's folder goes whole; a loose movie goes as its file; two movies in one folder go one by one.
        #expect(candidates.first { $0.id == 11 }?.kind == .movie)
        #expect(candidates.first { $0.id == 11 }?.size == 4100)   // put.io's folder size (artwork, subtitles…)
        #expect(candidates.first { $0.id == 12 }?.isFolder == false)
        #expect(!candidates.contains { $0.id == 15 })
    }

    @Test func aSeasonFolderInsideAMixedSeasonIsntWholeWhenItHoldsAnUnknownFolder() {
        // A Season 3 folder a download is about to save into (empty so far) keeps the show folder from going whole.
        let entries = RoomFixture.entries.filter { $0.match?.season == 1 }
        var folders = RoomFixture.folders.filter { $0.id != 23 }
        // Only Season 1 is in the show folder: the show folder could go whole…
        #expect(RoomPlanner.candidates(entries: entries, folders: folders, rules: RoomFixture.rules).map(\.id) == [21])
        // …but not with an empty folder in it, nor with a download saving into it.
        folders.append(RoomFixture.folder(24, "Season 3", parent: 21))
        #expect(RoomPlanner.candidates(entries: entries, folders: folders, rules: RoomFixture.rules).map(\.id) == [22])
        folders.removeLast()
        var rules = RoomFixture.rules
        rules.busyFolders = [21]
        #expect(RoomPlanner.candidates(entries: entries, folders: folders, rules: rules).map(\.id) == [22])
        // Subtitles beside the episodes don't count as unknown.
        folders.append(RoomFixture.folder(25, "Subs", parent: 22))
        #expect(RoomPlanner.candidates(entries: entries, folders: folders, rules: RoomFixture.rules).map(\.id) == [21])
    }

    @Test func keepsTheSeasonBeingGotButNotTheShowsOtherSeasons() {
        var rules = RoomFixture.rules
        rules.target = TransferTarget(tmdbID: 100, kind: .tv, title: "Show", posterPath: nil, backdropPath: nil, season: 3, episode: 3)
        let ids = RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).map(\.id)
        #expect(ids == [22, 23, 11, 151, 152, 12])
        // A whole show being got keeps every season of it.
        rules.target = TransferTarget(tmdbID: 100, kind: .tv, title: "Show", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
        #expect(RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).map(\.id) == [11, 151, 152, 12])
        // Another version of a movie keeps the copy there is.
        rules.target = TransferTarget(tmdbID: 1, kind: .movie, title: "Movie 1", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
        #expect(!RoomPlanner.candidates(entries: RoomFixture.entries, folders: RoomFixture.folders, rules: rules).contains { $0.id == 11 })
    }

    @Test func suggestsTheFewestFromTheFront() {
        let plan = RoomPlanner.plan(needed: 7000, entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules)
        #expect(plan.suggested == [22, 23])          // 6000 + 2500
        #expect(plan.freed(plan.suggested) == 8500)
        #expect(plan.isEnough)
        let small = RoomPlanner.plan(needed: 1, entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules)
        #expect(small.suggested == [22])
        // Unticking one recomputes what's freed; ids that aren't candidates are ignored.
        #expect(plan.freed([23, 999, 13]) == 2500)
        #expect(plan.chosen([12, 22]).map(\.id) == [22, 12])
    }

    @Test func notEnoughEvenWithEverythingSuggestsNothing() {
        let plan = RoomPlanner.plan(needed: 1_000_000, entries: RoomFixture.entries, folders: RoomFixture.folders, rules: RoomFixture.rules)
        #expect(!plan.isEnough)
        #expect(plan.suggested.isEmpty)
        #expect(plan.available == 6000 + 2500 + 4100 + 1000 + 1000 + 1000 + 1000 + 1500)
        let offer = RoomOffer(title: "Dune", size: 2_000_000, avail: 1000, plan: plan, action: .retry(transferID: 1), target: nil)
        #expect(!offer.canMakeRoom)
        #expect(offer.explanation?.contains("would free only") == true)
    }

    @Test func unknownSizesAreLeftOut() {
        var entries = RoomFixture.entries
        entries[1] = LibraryEntry(file: RoomFixture.video(12, "loose.mkv", parent: 10, size: nil, added: "2026-02-01T00:00:00"),
                                  match: RoomFixture.movie(2), folderName: nil)
        let ids = RoomPlanner.candidates(entries: entries, folders: RoomFixture.folders, rules: RoomFixture.rules).map(\.id)
        #expect(!ids.contains(12))
        // A folder with no size from put.io counts its videos.
        let folders = RoomFixture.folders.map { $0.id == 11 ? RoomFixture.folder(11, "Old Movie (2001)", parent: 10, added: "2026-01-01T00:00:00") : $0 }
        let movie = RoomPlanner.candidates(entries: RoomFixture.entries, folders: folders, rules: RoomFixture.rules).first { $0.id == 11 }
        #expect(movie?.size == 4000)
    }

    @Test func offerWording() {
        let offer = RoomOffer(title: "Severance · Season 2", size: 7_400_000_000, avail: 2_100_000_000, plan: nil,
                              action: .retry(transferID: 1), target: nil)
        #expect(offer.message == "Severance · Season 2 needs 7.4 GB, you have 2.1 GB free.")
        #expect(offer.needed == Int64(7_548_000_000 - 2_100_000_000))
        #expect(offer.explanation?.contains("Settings") == true)
        let target = TransferTarget(tmdbID: 1, kind: .tv, title: "Severance", posterPath: nil, backdropPath: nil, season: 2, episode: nil)
        #expect(RoomOffer.title(for: target) == "Severance · Season 2")
    }
}
