import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

/// Fix Match: files named as the anthology ("Monster.2022.S03E0x") put under "Monster: The Ed Gein Story" season 1.
@MainActor @Suite struct FixMatchTests {
    static let edGein = show(286801, "Monster: The Ed Gein Story", year: 2025)
    static let anime = show(30981, "Monster", year: 2004)

    /// TV Series / Monster (2022) / Season 3 / two episodes, plus a loose copy of episode 1 elsewhere.
    static func putio() -> FakePutio {
        let putio = FakePutio()
        putio.add(PutioFile(id: 1, name: "TV Series", fileType: "FOLDER", parentId: 0), to: 0)
        putio.add(PutioFile(id: 2, name: "Monster (2022)", fileType: "FOLDER", parentId: 1), to: 1)
        putio.add(PutioFile(id: 3, name: "Season 3", fileType: "FOLDER", parentId: 2), to: 2)
        putio.add(video(31, "Monster.2022.S03E01.1080p.NF.WEB-DL.mkv", in: 3, created: "2026-10-01"), to: 3)
        putio.add(video(32, "Monster.2022.S03E02.1080p.NF.WEB-DL.mkv", in: 3, created: "2026-10-02"), to: 3)
        putio.add(video(40, "Monster.S03E01.720p.mkv", in: 1, created: "2026-09-01"), to: 1)
        return putio
    }

    static func video(_ id: Int64, _ name: String, in parent: Int64, created: String) -> PutioFile {
        PutioFile(id: id, name: name, fileType: "VIDEO", size: 1_000_000_000, parentId: parent, createdAt: created)
    }

    /// TMDB search for "Monster" finds the 2004 anime only (one season), so nothing matches automatically.
    static let catalog = FakeCatalog(tvSearch: ["monster": [anime]], seasonCounts: [30981: 1])

    func rig(store: LocalStore = LocalStore(fileURL: nil)) -> LibraryIndex {
        let index = LibraryIndex(store: store)
        index.configure(putio: Self.putio(), catalog: Self.catalog)
        return index
    }

    func match(_ index: LibraryIndex, _ id: Int64) -> LibraryMatch? { index.entries.first { $0.id == id }?.match }

    @Test func overrideKeepsEpisodesAndSetsTheSeason() {
        let chosen = MatchOverride(item: Self.edGein, season: 1)
        let match = chosen.match(fileName: "Monster.2022.S03E05.1080p.mkv")
        #expect(match.tmdbID == 286801)
        #expect(match.season == 1)
        #expect(match.episode == 5)
        #expect(MatchOverride(item: Self.edGein).match(fileName: "Monster.2022.S03E05.mkv").season == 3)
        #expect(MatchOverride(item: Self.edGein).match(fileName: "05 - Episode.mkv").season == 1)
        #expect(MatchOverride(item: movie(1, "Heat"), season: 4).season == nil)
        #expect(MatchOverrides.nameKey("Monster.2022.S03E05.mkv") == MatchOverrides.nameKey("Monster 2022 S03E01 720p"))
        #expect(MatchOverrides.nameKey("Monster.2022.S03E05.mkv") != MatchOverrides.nameKey("Monster.2022.S02E05.mkv"))
    }

    @Test func folderFixAppliesNowAndOnEveryRefresh() async {
        let store = LocalStore(fileURL: nil)
        let index = rig(store: store)
        await index.refresh()
        // The 2004 anime has one season; "S03" files stay unmatched rather than going there.
        #expect(index.entries.allSatisfy { $0.match == nil })

        await index.fixMatch(.folder(id: 2, name: "Monster (2022)"), as: MatchOverride(item: Self.edGein, season: 1))
        #expect(match(index, 31)?.tmdbID == 286801)
        #expect(match(index, 31)?.season == 1)
        #expect(match(index, 32)?.episode == 2)
        #expect(match(index, 40) == nil, "outside the folder")
        #expect(index.matching(tmdbID: 286801, season: 1, episode: 2).map(\.id) == [32])

        // A fresh index on the same device state applies it again before automatic matching.
        let again = rig(store: store)
        await again.refresh(retryUnmatched: true)
        #expect(match(again, 31)?.tmdbID == 286801)
        #expect(match(again, 32)?.season == 1)
        #expect(await store.snapshot.matchOverrides.folders[2]?.tmdbID == 286801)
    }

    @Test func fileFixWinsOverFolderFix() async {
        let index = rig()
        await index.refresh()
        await index.fixMatch(.folder(id: 2, name: "Monster (2022)"), as: MatchOverride(item: Self.edGein, season: 1))
        await index.fixMatch(.files([Self.video(32, "Monster.2022.S03E02.1080p.NF.WEB-DL.mkv", in: 3, created: "2026-10-02")]),
                             as: MatchOverride(item: Self.anime))
        #expect(match(index, 31)?.tmdbID == 286801)
        #expect(match(index, 32)?.tmdbID == 30981)
        await index.refresh()
        #expect(match(index, 32)?.tmdbID == 30981)
    }

    @Test func sameNameFixCoversFilesInOtherFolders() async {
        let index = rig()
        await index.refresh()
        await index.fixMatch(.sameName("Monster.S03E01.720p.mkv"), as: MatchOverride(item: Self.edGein, season: 1))
        #expect(match(index, 40)?.tmdbID == 286801)
        #expect(match(index, 40)?.episode == 1)
        // "Monster.2022.S03…" has a year, so it's another name.
        #expect(match(index, 31) == nil)
    }

    @Test func matchAutomaticallyUndoesTheFix() async {
        let store = LocalStore(fileURL: nil)
        let index = rig(store: store)
        await index.refresh()
        let file = Self.video(31, "Monster.2022.S03E01.1080p.NF.WEB-DL.mkv", in: 3, created: "2026-10-01")
        await index.fixMatch(.folder(id: 2, name: "Monster (2022)"), as: MatchOverride(item: Self.edGein, season: 1))
        #expect(index.hasOverride([file]))

        // Undo from one file of the folder: the folder's choice goes, every file it covered is looked up again.
        let released = await index.matchAutomatically([file])
        #expect(released == 2)
        #expect(!index.hasOverride([file]))
        #expect(match(index, 31) == nil)
        #expect(match(index, 32) == nil)
        #expect(await store.snapshot.matchOverrides.isEmpty)
        await index.refresh()
        #expect(match(index, 31) == nil)
    }

    @Test func requestsOfferFileFolderAndName() {
        let file = Self.video(31, "Monster.2022.S03E01.1080p.mkv", in: 3, created: "2026-10-01")
        let request = FixMatchRequest.video(file, folderName: "Season 3")
        #expect(request.targets == [.files([file]), .folder(id: 3, name: "Season 3"), .sameName(file.name)])
        #expect(FixMatchTarget.sameName(file.name).label == "All files named \u{201C}Monster 2022\u{201D} season 3")
        #expect(FixMatchRequest.folder(PutioFile(id: 2, name: "Monster (2022)", fileType: "FOLDER")).targets
            == [.folder(id: 2, name: "Monster (2022)")])
        #expect(FixMatchModel.suggestedQuery("Monster.2022.S03E01.1080p.mkv") == "Monster")
    }

    @Test func modelSearchesChoosesSeasonAndApplies() async throws {
        var catalog = Self.catalog
        catalog.multi = ["monster the ed gein": [Self.edGein, CatalogItem(tmdbID: 5, mediaType: .person, title: "Someone")]]
        catalog.details = [286801: TitleDetail(item: Self.edGein, imdbID: nil,
                                               seasons: [SeasonSummary(number: 1, name: "Miniseries", episodeCount: 8, posterPath: nil)])]
        let index = LibraryIndex(store: LocalStore(fileURL: nil))
        index.configure(putio: Self.putio(), catalog: catalog)
        await index.refresh()
        let file = Self.video(31, "Monster.2022.S03E01.1080p.NF.WEB-DL.mkv", in: 3, created: "2026-10-01")
        let model = FixMatchRequest.video(file, folderName: "Season 3").model(catalog: catalog, library: index)
        #expect(model.query == "Monster")
        #expect(model.namedSeason == 3)
        model.query = "Monster the Ed Gein"
        model.search()
        try await waitUntil { !model.isSearching }
        #expect(model.results.map(\.tmdbID) == [286801])
        await model.choose(Self.edGein)
        #expect(model.seasons.map(\.number) == [1])
        #expect(model.season == 1, "a miniseries is its one season whatever the names say")
        model.target = .folder(id: 3, name: "Season 3")
        #expect(await model.apply() == "Matched to Monster: The Ed Gein Story")
        #expect(match(index, 32)?.tmdbID == 286801)
        #expect(match(index, 32)?.season == 1)
    }
}
