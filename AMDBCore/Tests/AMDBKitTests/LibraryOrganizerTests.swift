import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct LibraryOrganizerTests {
    static func folder(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "FOLDER", parentId: parent)
    }

    static func video(_ id: Int64, _ name: String, in parent: Int64) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "VIDEO", size: 2_000_000_000, parentId: parent)
    }

    static func entry(_ file: PutioFile, _ match: LibraryMatch?) -> LibraryEntry {
        LibraryEntry(file: file, match: match, folderName: nil)
    }

    static let dune = LibraryMatch(tmdbID: 693134, mediaType: .movie, season: nil, episode: nil, confidence: 0.95, title: "Dune: Part Two", year: 2024)
    static let heat = LibraryMatch(tmdbID: 949, mediaType: .movie, season: nil, episode: nil, confidence: 0.95, title: "Heat", year: 1995)
    static func severance(_ episode: Int, confidence: Double = 0.9) -> LibraryMatch {
        LibraryMatch(tmdbID: 95396, mediaType: .tv, season: 2, episode: episode, confidence: confidence, title: "Severance")
    }

    /// root: Movies (with one movie already inside a release folder), a chill download folder with a movie
    /// release folder and a season pack, a "Downloads" folder holding one movie, a loose episode in root,
    /// and an unrecognized file.
    static func world() -> (FakePutio, [LibraryEntry]) {
        let putio = FakePutio()
        let files: [(PutioFile, Int64)] = [
            (folder(2, "Movies", in: 0), 0),
            (folder(3, "Heat.1995.1080p.BluRay", in: 2), 2), (video(31, "Heat.1995.1080p.BluRay.mkv", in: 3), 3),
            (folder(4, "chill", in: 0), 0),
            (folder(5, "Dune.Part.Two.2024.2160p.WEB-DL", in: 4), 4), (video(51, "Dune.Part.Two.2024.2160p.WEB-DL.mkv", in: 5), 5),
            (folder(6, "Severance.S02.1080p.WEB", in: 4), 4),
            (video(61, "Severance.S02E01.mkv", in: 6), 6), (video(62, "Severance.S02E02.mkv", in: 6), 6),
            (folder(7, "Downloads", in: 0), 0), (video(71, "Dune.Part.Two.2024.720p.mkv", in: 7), 7),
            (video(81, "Severance.S02E03.1080p.mkv", in: 0), 0),
            (video(91, "home.video.2019.mkv", in: 0), 0),
        ]
        for (file, parent) in files { putio.add(file, to: parent) }
        let entries = [
            entry(video(31, "Heat.1995.1080p.BluRay.mkv", in: 3), heat),
            entry(video(51, "Dune.Part.Two.2024.2160p.WEB-DL.mkv", in: 5), dune),
            entry(video(61, "Severance.S02E01.mkv", in: 6), severance(1)),
            entry(video(62, "Severance.S02E02.mkv", in: 6), severance(2)),
            entry(video(71, "Dune.Part.Two.2024.720p.mkv", in: 7), dune),
            entry(video(81, "Severance.S02E03.1080p.mkv", in: 0), severance(3)),
            entry(video(91, "home.video.2019.mkv", in: 0), nil),
        ]
        return (putio, entries)
    }

    @Test func plansSafeMoves() async throws {
        let (putio, entries) = Self.world()
        let plan = try await LibraryOrganizer.plan(entries: entries, layout: .standard, putio: putio, store: LocalStore(fileURL: nil))
        let summary = plan.moves.map { "\($0.name) -> \($0.destination)\($0.isFolder ? " [folder]" : "")" }
        #expect(summary == [
            "Dune.Part.Two.2024.2160p.WEB-DL -> Movies [folder]",
            "Dune.Part.Two.2024.720p.mkv -> Movies",
            "Severance.S02.1080p.WEB -> TV Series/Severance/Season 2 [folder]",
            "Severance.S02E03.1080p.mkv -> TV Series/Severance/Season 2",
        ])
        #expect(plan.inPlace == 1, "Heat already sits in a release folder inside Movies")
        #expect(plan.unrecognized.map(\.id) == [91])
    }

    @Test func folderTreeGivesTheSamePlanWithoutListingPutio() async throws {
        let (putio, entries) = Self.world()
        let tree = FolderTree(folders: [Self.folder(2, "Movies", in: 0),
                                        Self.folder(3, "Heat.1995.1080p.BluRay", in: 2), Self.folder(4, "chill", in: 0),
                                        Self.folder(5, "Dune.Part.Two.2024.2160p.WEB-DL", in: 4),
                                        Self.folder(6, "Severance.S02.1080p.WEB", in: 4), Self.folder(7, "Downloads", in: 0)])
        let store = LocalStore(fileURL: nil)
        let fromNetwork = try await LibraryOrganizer.plan(entries: entries, layout: .standard, putio: putio, store: store)
        let calls = putio.listCalls
        let fromTree = try await LibraryOrganizer.plan(entries: entries, layout: .standard, putio: putio, store: store, tree: tree)
        #expect(fromTree == fromNetwork)
        #expect(putio.listCalls == calls, "no folder listings when the tree is known")
    }

    @Test func applyCreatesFoldersAndMovesOncePerDestination() async throws {
        let (putio, entries) = Self.world()
        let store = LocalStore(fileURL: nil)
        let plan = try await LibraryOrganizer.plan(entries: entries, layout: .standard, putio: putio, store: store)
        let moved = try await LibraryOrganizer.apply(plan, layout: .standard, putio: putio, store: store)
        #expect(moved == 4)
        #expect(putio.createdFolders == ["TV Series", "Severance", "Season 2"])
        #expect(putio.moved.map { $0.ids.sorted() } == [[5, 71], [6, 81]])
        #expect(putio.moved.first?.parent == 2)
    }

    @Test func lowConfidenceAndShowFoldersStayPut() async throws {
        let putio = FakePutio()
        putio.add(Self.folder(2, "TV Series", in: 0), to: 0)
        putio.add(Self.folder(3, "Severance", in: 2), to: 2)
        putio.add(Self.video(31, "Severance.S02E04.mkv", in: 3), to: 3)
        putio.add(Self.video(32, "Severance.S02E05.mkv", in: 3), to: 3)
        putio.add(Self.video(41, "Something.2020.mkv", in: 0), to: 0)
        let entries = [
            Self.entry(Self.video(31, "Severance.S02E04.mkv", in: 3), Self.severance(4)),
            Self.entry(Self.video(32, "Severance.S02E05.mkv", in: 3), Self.severance(5)),
            Self.entry(Self.video(41, "Something.2020.mkv", in: 0), Self.severance(1, confidence: 0.5)),
        ]
        let plan = try await LibraryOrganizer.plan(entries: entries, layout: .standard, putio: putio, store: LocalStore(fileURL: nil))
        // Episodes in the old show folder move into Season 2 one by one; the show folder itself never moves.
        #expect(plan.moves.map(\.itemID) == [31, 32])
        #expect(plan.moves.allSatisfy { !$0.isFolder })
        #expect(plan.unrecognized.map(\.id) == [41])
    }

    @Test func needsReleaseEvidenceBeforeMoving() {
        let crawler = LibraryMatch(tmdbID: 5, mediaType: .movie, season: nil, episode: nil, confidence: 0.9, title: "The Web Crawler", year: 2011)
        #expect(!LibraryOrganizer.isConfident(Self.entry(Self.video(1, "10. Web Crawler Q&A.mp4", in: 0), crawler)), "no year")
        #expect(!LibraryOrganizer.isConfident(Self.entry(Self.video(2, "Dune.Part.Two.1984.mkv", in: 0), Self.dune)), "wrong year")
        #expect(LibraryOrganizer.isConfident(Self.entry(Self.video(3, "Dune.Part.Two.2024.mkv", in: 0), Self.dune)))
        #expect(LibraryOrganizer.isConfident(LibraryEntry(file: Self.video(4, "movie.mkv", in: 9), match: Self.dune,
                                                          folderName: "Dune.Part.Two.2024.1080p")), "year from the folder")
        #expect(!LibraryOrganizer.isConfident(Self.entry(Self.video(5, "Severance pilot.mkv", in: 0), Self.severance(1))), "no episode")
        #expect(LibraryOrganizer.isConfident(Self.entry(Self.video(6, "Severance.S02E01.mkv", in: 0), Self.severance(1))))
    }

    @Test func releaseFolderNames() {
        #expect(LibraryOrganizer.looksLikeRelease("Dune.Part.Two.2024.2160p.WEB-DL", of: Self.dune))
        #expect(!LibraryOrganizer.looksLikeRelease("Downloads", of: Self.dune))
        #expect(!LibraryOrganizer.looksLikeRelease("Severance", of: Self.severance(1)))
        #expect(LibraryOrganizer.looksLikeRelease("Severance.S02.1080p.WEB", of: Self.severance(1)))
    }
}
