import AMDBCore
import AMDBKit
import Foundation

/// `-demo` swaps in fake services so every screen can be exercised without credentials.
/// `-demoScreen title|show|versions|search|library|movies|player` opens a screen at launch.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-demoScreen"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @MainActor static func makeModel() -> AppModel {
        let putio = DemoPutio()
        let factory = ServiceFactory(
            makePutio: { _ in putio },
            makeCatalog: { _ in DemoCatalog() },
            makeProvider: { config, _ in DemoProvider(id: config.id) },
            makeCharts: { _ in DemoCharts() },
            episodeRatings: DemoEpisodeRatings(),
            makeSubtitles: { _ in DemoSubtitles() },
            makeChillCatalog: { _ in DemoChill() },
            latestLists: [])
        let model = AppModel(tokens: InMemoryTokenStore([.putio: "demo", .tmdb: "demo", .chill: "demo"]),
                             defaults: UserDefaults(suiteName: "amdb.demo") ?? .standard,
                             store: LocalStore(fileURL: nil), factory: factory, bundledTraktClientID: "demo",
                             bundledOpenSubtitlesKey: "demo")
        // One finished and one running download, so the Downloads screens have something to show.
        Task {
            await model.downloads.upsert(DownloadRecord(fileID: 2, title: "Severance", posterPath: nil, tmdbID: 95396, kind: .tv,
                                                        season: 2, episode: 4, state: .done(relativePath: "Library/demo.movpkg")))
            await model.downloads.upsert(DownloadRecord(fileID: 3, title: "Heat", posterPath: nil, tmdbID: 949, kind: .movie,
                                                        season: nil, episode: nil, state: .downloading(progress: 0.42)))
        }
        return model
    }

    #if os(iOS)
    @MainActor static func apply(to router: Router) {
        switch screen {
        case "title": router.homePath = [.title(DemoCatalog.movies[0])]
        case "show": router.homePath = [.title(DemoCatalog.shows[0])]
        case "versions":
            router.homePath = [.title(DemoCatalog.movies[0])]
            router.versions = VersionsRequest(query: .movie(imdbID: "tt0", title: DemoCatalog.movies[0].title, year: 2024),
                                              target: nil, playNow: [])
        case "search": router.tab = .search
        case "library": router.tab = .library
        case "files":
            router.tab = .library
            router.libraryPath = [.files(.root)]
        case "movies": router.tab = .movies
        case "upcoming": router.tab = .upcoming
        case "person": router.homePath = [.person(900)]
        case "collection": router.homePath = [.collection(8945)]
        case "surprise": router.showSurprise = true
        case "settings": router.showSettings = true
        case "chart":
            router.tab = .movies
            router.moviesPath = [.chart(.top250Movies)]
        case "player":
            router.player = PlayerRequest(file: PutioFile(id: 1, name: "Interstellar.2014.1080p.BluRay.x264.mkv", fileType: "VIDEO"),
                                          title: "Interstellar", resumeFrom: 4360, played: nil, next: nil)
        case "player-episode":
            // Severance S2 E4, a few seconds before the credits, to show the Next Episode card.
            router.player = PlayerRequest(file: PutioFile(id: 2, name: "Severance.S02E04.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO"),
                                          title: "Severance", resumeFrom: 1745,
                                          played: PlayedTitle(tmdbID: DemoCatalog.shows[0].tmdbID, kind: .tv, title: "Severance"),
                                          next: nil, season: 2, episode: 4)
        default: break
        }
    }
    #endif
}

struct DemoCatalog: CatalogService {
    /// Real TMDB artwork (poster, backdrop, logo) so demo screens look like the real thing.
    static let art: [String: (poster: String, backdrop: String, logo: String?)] = [
        "Furiosa: A Mad Max Saga": ("/iADOJ8Zymht2JPMoy3R7xceZprc.jpg", "/raph7qjAGTMXaIjVxt6ZDSXRzUr.jpg", "/z1wMCU7yPf6YELf46S2ml8XFDdR.png"),
        "Dune: Part Two": ("/6izwz7rsy95ARzTR3poZ8H6c5pp.jpg", "/eZ239CUp1d6OryZEBPnO2n87gMG.jpg", "/eYvF1LhPKuoBxOAmWjFTAK7EPWl.png"),
        "Interstellar": ("/yQvGrMoipbRoddT0ZR8tPoR7NfX.jpg", "/8sNiAPPYU14PUepFNeSNGUTiHW.jpg", "/4Hu4w5p0mwL2Wvyk3gqu2JRDGHl.png"),
        "Past Lives": ("/k3waqVXSnvCZWfJYNtdamTgTtTA.jpg", "/7HR38hMBl23lf38MAN63y4pKsHz.jpg", "/jzdqCuDygikoTJfYdRRTJp0xYsd.png"),
        "Oppenheimer": ("/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg", "/neeNHeXjMF5fXoCJRsOmkNGC7q.jpg", "/b07VisHvZb0WzUpA8VB77wfMXwg.png"),
        "Blade Runner 2049": ("/gajva2L0rPYkEWjzgFlBXCAVBE5.jpg", "/gNdLJU9TxrpGx4dkZidjys3fyy0.jpg", "/gUoDt6GggEFXVzdyDTyF8ggrEm8.png"),
        "Arrival": ("/pEzNVQfdzYDzVK0XqxERIw2x2se.jpg", "/8MUZz7oPXQftFTslZpRP3CVMOoq.jpg", "/rcPtxYkZ2mXmKdD0NKLzjsHxL3V.png"),
        "Heat": ("/umSVjVdbVwtx5ryCA2QXL44Durm.jpg", "/uI22JkEMediWyiRqhllNqeeGtW0.jpg", nil),
        "Parasite": ("/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg", "/TU9NIjwzjoKPwQHoHshkFcQUCG.jpg", "/eEGZWCv0OYbMLCaNsDl1cgrvnWR.png"),
        "Everything Everywhere All at Once": ("/u68AjlvlutfEIcpmbYpKcdi09ut.jpg", "/fIwiFha3WPu5nHkBeMQ4GzEk0Hv.jpg", "/6rpxXCCaVtj5u4dWANfdRoVgDQV.png"),
        "Severance": ("/pPHpeI2X1qEd1CS1SeyrdhZ4qnT.jpg", "/ixgFmf1X59PUZam2qbAfskx2gQr.jpg", "/yyS1tALk7t3YdTNMOvR5gsnXINA.png"),
        "Shōgun": ("/7O4iVfOMQmdCSxhOg1WnzG1AgYT.jpg", "/bwSmgmd90hCWwqOKQYTEraeOZhJ.jpg", "/eqWtUYYsmW7cPkXzxAF8idOPEX8.png"),
        "The Bear": ("/eKfVzzEazSIjJMrw9ADa2x8ksLz.jpg", "/aJtG4txtmiRHwAAqENQHZvBs6kY.jpg", "/8ZTz2Wj0lE5WoSOqRG8GarhhnY4.png"),
        "Andor": ("/khZqmwHQicTYoS7Flreb9EddFZC.jpg", "/quCeAmVQHfsdcYkicbxZWVauCVb.jpg", "/2vyPbpZVYkYAzU8QqyGi6EmawB5.png"),
        "Slow Horses": ("/AdYr4DjOgXvDUMwu6vEhZy1Rnxk.jpg", "/gPQppUnLx9vqPDLz3WwZ2HJsNbt.jpg", "/peE0Gab2MWjXPlAYhakxjHciNPr.png"),
        "The Last of Us": ("/dmo6TYuuJgaYinXBPjrgG9mB5od.jpg", "/lY2DhbA7Hy44fAKddr06UrXWWaQ.jpg", "/msYtgZbEo8tAOJ37T50kgqulpKf.png"),
    ]
    static let cast: [CastMember] = [
        CastMember(name: "Anya Taylor-Joy", character: "Furiosa", profilePath: "/yZpghhtKM2VZHDx6JGAZqAVU4PL.jpg", id: 1397778),
        CastMember(name: "Chris Hemsworth", character: "Dementus", profilePath: "/piQGdoIQOF3C1EI5cbYZLAW1gfj.jpg", id: 74568),
        CastMember(name: "Tom Burke", character: "Praetorian Jack", profilePath: "/4IHlAZ9bJ82VAd6HUOWFgo81SDq.jpg", id: 52891),
        CastMember(name: "Alyla Browne", character: "Young Furiosa", profilePath: "/h9qYvAqEZS6HTQhE8zLA0q3u52n.jpg", id: 2431565),
        CastMember(name: "George Shevtsov", character: "The History Man", profilePath: "/cuOoCZShfvNrOvrWqH2dPyBfrZS.jpg", id: 148899),
        CastMember(name: "Lachy Hulme", character: "Immortan Joe", profilePath: "/z6ZEqpIkh1LYQXgSNMcc8akW3ZR.jpg", id: 75122),
    ]

    static let movies: [CatalogItem] = [
        ("Furiosa: A Mad Max Saga", 2024, "As the world fell, young Furiosa is snatched from the Green Place of Many Mothers."),
        ("Dune: Part Two", 2024, "Paul Atreides unites with Chani and the Fremen while on a path of revenge."),
        ("Interstellar", 2014, "A team of explorers travel through a wormhole in space."),
        ("Past Lives", 2023, "Two childhood friends reunite in New York for one fateful week."),
        ("Oppenheimer", 2023, "The story of J. Robert Oppenheimer and the atomic bomb."),
        ("Blade Runner 2049", 2017, "A new blade runner unearths a long-buried secret."),
        ("Arrival", 2016, "A linguist works with the military to communicate with alien lifeforms."),
        ("Heat", 1995, "A group of high-end professional thieves start to feel the heat from the LAPD."),
        ("Parasite", 2019, "Greed and class discrimination threaten a newly formed symbiotic relationship."),
        ("Everything Everywhere All at Once", 2022, "A middle-aged immigrant is swept up in an insane adventure."),
    ].enumerated().map { index, entry in
        CatalogItem(tmdbID: 100 + index, mediaType: .movie, title: entry.0, overview: entry.2,
                    posterPath: art[entry.0]?.poster, backdropPath: art[entry.0]?.backdrop, year: entry.1, voteAverage: 7.4 + Double(index % 5) / 5)
    }

    static let shows: [CatalogItem] = [
        ("Severance", 2022), ("Shōgun", 2024), ("The Bear", 2022), ("Andor", 2022), ("Slow Horses", 2022), ("The Last of Us", 2023),
    ].enumerated().map { index, entry in
        CatalogItem(tmdbID: 200 + index, mediaType: .tv, title: entry.0, overview: "A prestige series everyone keeps recommending.",
                    posterPath: art[entry.0]?.poster, backdropPath: art[entry.0]?.backdrop, year: entry.1, voteAverage: 8.4)
    }

    private static var everything: [CatalogItem] { movies + shows }

    func validate() async throws {}
    func searchMulti(_ query: String) async throws -> [CatalogItem] {
        try await Task.sleep(for: .milliseconds(120))
        return Self.everything.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    func searchMulti(_ query: String, page: Int) async throws -> CatalogPage {
        CatalogPage(items: page == 1 ? try await searchMulti(query) : [], page: page, totalPages: 1)
    }
    func trending(_ kind: MediaKind?) async throws -> [CatalogItem] { Array(Self.movies.prefix(4)) + Array(Self.shows.prefix(3)) }
    func popular(_ kind: MediaKind) async throws -> [CatalogItem] { kind == .tv ? Self.shows : Self.movies }
    func topRated(_ kind: MediaKind) async throws -> [CatalogItem] { (kind == .tv ? Self.shows : Self.movies).reversed() }
    func discover(_ kind: MediaKind, genreID: Int) async throws -> [CatalogItem] {
        let pool = kind == .tv ? Self.shows : Self.movies
        let shift = genreID % pool.count
        return Array(pool[shift...] + pool[..<shift])
    }
    func detail(_ kind: MediaKind, id: Int) async throws -> TitleDetail {
        guard let item = Self.everything.first(where: { $0.tmdbID == id }) else { throw AppError.http(service: "tmdb", status: 404) }
        let cast = Self.cast
        let seasons = kind == .tv ? (1...2).map { SeasonSummary(number: $0, name: "Season \($0)", episodeCount: 8, posterPath: nil) } : []
        // Furiosa uses its real IMDb id so demo mode exercises real IMDb trailers.
        let imdbID = item.title.hasPrefix("Furiosa") ? "tt12037194" : "tt\(id)"
        return TitleDetail(item: item, imdbID: imdbID, runtimeMinutes: kind == .tv ? 55 : 148,
                           genres: kind == .tv ? ["Drama", "Mystery"] : ["Action", "Adventure", "Science Fiction"],
                           cast: cast, trailerYouTubeKey: "zSWdZVtXT7E", logoPath: Self.art[item.title]?.logo,
                           recommendations: Array(Self.movies.shuffled().prefix(8)), seasons: seasons,
                           collection: item.title.hasPrefix("Furiosa")
                               ? CollectionRef(id: 8945, name: "Mad Max Collection", posterPath: "/tRxkZboyyXnFgCthoViWBwISZ0r.jpg",
                                               backdropPath: "/zI0q2ENcQOLECbe0gAEGlncVh2j.jpg") : nil)
    }
    func season(tvID: Int, number: Int) async throws -> [Episode] {
        (1...8).map { Episode(number: $0, name: "Episode \($0)", overview: "Things get complicated at Lumon.",
                              stillPath: Self.art["Severance"]?.backdrop, runtimeMinutes: 50 + $0, airDate: "2025-0\(min($0, 9))-01") }
    }
    func person(id: Int) async throws -> PersonDetail {
        PersonDetail(id: id, name: "Anya Taylor-Joy",
                     biography: "An actress known for intense, transformative roles across film and television.",
                     profilePath: "/yZpghhtKM2VZHDx6JGAZqAVU4PL.jpg", department: "Acting", birthday: "1996-04-16", placeOfBirth: "Miami, Florida, USA",
                     credits: Self.movies, knownFor: Array(Self.movies.prefix(5)))
    }
    func collection(id: Int) async throws -> CollectionDetail {
        CollectionDetail(id: id, name: "Mad Max Collection", overview: "A post-apocalyptic saga of survival on the Fury Road.",
                         posterPath: "/tRxkZboyyXnFgCthoViWBwISZ0r.jpg", backdropPath: "/zI0q2ENcQOLECbe0gAEGlncVh2j.jpg", parts: Array(Self.movies.prefix(5)))
    }
    private static func day(_ offset: Int) -> String { CuratedList.day(Date(), plus: offset) }
    func upcomingMovies(region: String) async throws -> [DatedItem] {
        Self.movies.suffix(5).enumerated().map { DatedItem(item: $0.element, date: Self.day(4 + $0.offset * 9)) }
    }
    func discoverDated(_ kind: MediaKind, query: DiscoverQuery) async throws -> [DatedItem] {
        (kind == .tv ? Self.shows : Self.movies).reversed().enumerated().map { DatedItem(item: $0.element, date: Self.day(2 + $0.offset * 5)) }
    }
    func nextEpisode(tvID: Int) async throws -> UpcomingEpisode? {
        guard let index = Self.shows.firstIndex(where: { $0.tmdbID == tvID }) else { return nil }
        return UpcomingEpisode(show: Self.shows[index], season: 2, episode: 5 + index, name: "The Next One",
                               airDate: Self.day(index), stillPath: nil)
    }
    func discover(_ kind: MediaKind, genreIDs: [Int], minRating: Double, minVotes: Int, page: Int) async throws -> CatalogPage {
        CatalogPage(items: kind == .tv ? Self.shows : Self.movies, page: page, totalPages: 1)
    }
    func item(_ kind: MediaKind, id: Int) async throws -> CatalogItem {
        guard let item = Self.everything.first(where: { $0.tmdbID == id }) else { throw AppError.http(service: "tmdb", status: 404) }
        return item
    }
    /// `-demoSlowLibrary` makes matching slow, to see the first-launch loading row.
    private func slowIfAsked() async {
        if ProcessInfo.processInfo.arguments.contains("-demoSlowLibrary") { try? await Task.sleep(for: .seconds(4)) }
    }
    func searchMovie(title: String, year: Int?) async throws -> [CatalogItem] {
        await slowIfAsked()
        return Self.movies.filter { LibraryMatcher.normalize($0.title) == LibraryMatcher.normalize(title) }
    }
    func searchTV(title: String, year: Int?) async throws -> [CatalogItem] {
        await slowIfAsked()
        return Self.shows.filter { LibraryMatcher.normalize($0.title) == LibraryMatcher.normalize(title) }
    }
}

final class DemoPutio: PutioService, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: Int64 = 9000
    private var transfersStarted: [Int64: Date] = [:]
    private var extraFiles: [Int64: PutioFile] = [:]

    private let rootFiles: [PutioFile] = [
        PutioFile(id: 1, name: "Interstellar.2014.1080p.BluRay.x264.mkv", fileType: "VIDEO", size: 9_000_000_000,
                  createdAt: "2026-10-10T10:00:00", updatedAt: "2026-10-12T21:00:00", startFrom: 4360),
        PutioFile(id: 2, name: "Severance.S02E04.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO", size: 2_000_000_000,
                  createdAt: "2026-10-11T10:00:00", updatedAt: "2026-10-12T22:00:00", startFrom: 1250),
        PutioFile(id: 3, name: "Past.Lives.2023.1080p.WEB.mkv", fileType: "VIDEO", size: 3_000_000_000,
                  createdAt: "2026-10-09T10:00:00", startFrom: 0),
        PutioFile(id: 4, name: "Heat.1995.REMASTERED.1080p.BluRay.mkv", fileType: "VIDEO", size: 11_000_000_000,
                  createdAt: "2026-10-01T10:00:00", updatedAt: "2026-10-03T10:00:00", startFrom: 600),
        PutioFile(id: 5, name: "Home.Video.2019.mov", fileType: "VIDEO", size: 300_000_000, createdAt: "2026-09-01T10:00:00"),
        PutioFile(id: 6, name: "Severance.S02E05.1080p.WEB.H264-NTb.mkv", fileType: "VIDEO", size: 2_000_000_000,
                  createdAt: "2026-08-20T10:00:00"),
    ]

    /// The rest of the demo put.io: a couple of folders with non-video files, for the file manager.
    private lazy var tree: [Int64: [PutioFile]] = [
        0: rootFiles + [PutioFile(id: 50, name: "Downloads", fileType: "FOLDER", size: 52_000_000, parentId: 0,
                                  createdAt: "2026-09-12T10:00:00"),
                        PutioFile(id: 51, name: "Archive", fileType: "FOLDER", size: 0, parentId: 0, createdAt: "2026-06-02T10:00:00")],
        50: [PutioFile(id: 52, name: "Severance.Poster.jpg", fileType: "IMAGE", size: 2_400_000, parentId: 50,
                       createdAt: "2026-09-12T10:00:00"),
             PutioFile(id: 53, name: "Release.Notes.txt", fileType: "TEXT", size: 4_000, parentId: 50, createdAt: "2026-09-13T10:00:00"),
             PutioFile(id: 54, name: "Soundtrack.zip", fileType: "ARCHIVE", size: 49_600_000, parentId: 50,
                       createdAt: "2026-09-14T10:00:00")],
        51: [],
    ]
    private var trashed: [PutioTrashFile] = [
        PutioTrashFile(id: 60, name: "Old.Movie.2001.720p.mkv", fileType: "VIDEO", size: 4_200_000_000,
                       deletedAt: "2026-10-12T10:00:00", expirationDate: "2026-11-11T10:00:00"),
    ]

    func accountInfo() async throws -> PutioAccount {
        let trash = lock.withLock { trashed.reduce(0) { $0 + ($1.size ?? 0) } }
        return PutioAccount(username: "demo", disk: .init(avail: 640_000_000_000, size: 1_000_000_000_000, used: 360_000_000_000),
                            trashSize: trash)
    }

    func deleteFiles(ids: [Int64]) async throws {
        lock.withLock {
            for (parent, files) in tree {
                for file in files where ids.contains(file.id) {
                    trashed.insert(PutioTrashFile(id: file.id, name: file.name, fileType: file.fileType, size: file.size,
                                                  deletedAt: "2026-10-14T10:00:00", expirationDate: "2026-11-13T10:00:00"), at: 0)
                }
                tree[parent] = files.filter { !ids.contains($0.id) }
            }
        }
    }

    func moveFiles(ids: [Int64], to parentID: Int64) async throws {
        lock.withLock {
            var moving: [PutioFile] = []
            for (parent, files) in tree {
                moving += files.filter { ids.contains($0.id) }
                tree[parent] = files.filter { !ids.contains($0.id) }
            }
            tree[parentID, default: []] += moving
        }
    }

    func renameFile(id: Int64, name: String) async throws {
        lock.withLock {
            for (parent, files) in tree {
                tree[parent] = files.map { file in
                    file.id == id ? PutioFile(id: id, name: name, fileType: file.fileType, size: file.size, parentId: file.parentId,
                                              createdAt: file.createdAt, startFrom: file.startFrom) : file
                }
            }
        }
    }

    func copyFile(id: Int64, to parentID: Int64) async throws -> PutioFile {
        try lock.withLock {
            guard let file = tree.values.joined().first(where: { $0.id == id }) else { throw AppError.http(service: "putio", status: 404) }
            nextID += 1
            let copy = PutioFile(id: nextID, name: file.name, fileType: file.fileType, size: file.size, parentId: parentID,
                                 createdAt: "2026-10-14T10:00:00")
            tree[parentID, default: []].append(copy)
            return copy
        }
    }

    func searchFiles(_ query: String) async throws -> [PutioFile] {
        lock.withLock { tree.values.joined().filter { $0.name.localizedCaseInsensitiveContains(query) } }
    }

    func trash() async throws -> PutioTrash {
        lock.withLock { PutioTrash(files: trashed, trashSize: trashed.reduce(0) { $0 + ($1.size ?? 0) }) }
    }

    func restoreFromTrash(ids: [Int64]) async throws {
        lock.withLock {
            for file in trashed where ids.contains(file.id) {
                tree[0, default: []].append(PutioFile(id: file.id, name: file.name, fileType: file.fileType, size: file.size,
                                                      parentId: 0, createdAt: file.deletedAt))
            }
            trashed.removeAll { ids.contains($0.id) }
        }
    }

    func deleteFromTrash(ids: [Int64]) async throws { lock.withLock { trashed.removeAll { ids.contains($0.id) } } }
    func emptyTrash() async throws { lock.withLock { trashed = [] } }

    func addTransfer(url: String, saveParentID: Int64?) async throws -> PutioTransfer {
        let id = lock.withLock { () -> Int64 in
            nextID += 1
            transfersStarted[nextID] = Date()
            return nextID
        }
        return try await transfer(id: id)
    }

    /// Demo transfers download for ~8 seconds, then complete into a new video file.
    func transfer(id: Int64) async throws -> PutioTransfer {
        guard let started = lock.withLock({ transfersStarted[id] }) else { throw AppError.http(service: "putio", status: 404) }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed < 8 {
            let percent = Int(elapsed / 8 * 100)
            return PutioTransfer(id: id, name: "Demo", status: "DOWNLOADING", percentDone: percent, downSpeed: 48_000_000,
                                 peersConnected: 112, estimatedTime: Int64(8 - elapsed), downloaded: Int64(percent) * 30_000_000)
        }
        let fileID = id + 100_000
        lock.withLock {
            extraFiles[fileID] = PutioFile(id: fileID, name: "Demo.Release.1080p.mkv", fileType: "VIDEO", size: 3_000_000_000,
                                           createdAt: "2026-10-13T10:00:00")
        }
        return PutioTransfer(id: id, name: "Demo", status: "COMPLETED", percentDone: 100, hash: nil, fileId: fileID)
    }

    func transfers() async throws -> [PutioTransfer] { [] }
    func cancelTransfers(ids: [Int64]) async throws { lock.withLock { ids.forEach { transfersStarted[$0] = nil } } }
    func retryTransfer(id: Int64) async throws -> PutioTransfer { try await transfer(id: id) }

    func listFiles(parentID: Int64) async throws -> PutioFileList {
        lock.withLock {
            let parent = parentID == 0 ? PutioFile(id: 0, name: "Your Files", fileType: "FOLDER")
                : tree.values.joined().first { $0.id == parentID }
            return PutioFileList(parent: parent, files: tree[parentID] ?? [])
        }
    }

    func file(id: Int64) async throws -> PutioFile {
        if let file = lock.withLock({ tree.values.joined().first { $0.id == id } ?? extraFiles[id] }) { return file }
        return PutioFile(id: id, name: "Folder", fileType: "FOLDER")
    }

    func createFolder(name: String, parentID: Int64) async throws -> PutioFile {
        lock.withLock {
            nextID += 1
            let folder = PutioFile(id: nextID, name: name, fileType: "FOLDER", size: 0, parentId: parentID, createdAt: "2026-10-14T10:00:00")
            tree[parentID, default: []].append(folder)
            return folder
        }
    }

    func startFrom(fileID: Int64) async throws -> Int { 0 }
    func setStartFrom(fileID: Int64, seconds: Int) async throws {}
    func hlsURL(fileID: Int64, subtitles: Bool) -> URL {
        // Like put.io: subtitle tracks only when asked for (the app streams without them and draws its own).
        subtitles
            ? URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!
            : URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")!
    }
    func originalURL(fileID: Int64) async throws -> URL { hlsURL(fileID: fileID) }
    func subtitles(fileID: Int64) async throws -> [PutioSubtitle] {
        [PutioSubtitle(key: "eng-mkv", language: "English", languageCode: "eng", name: "English (from the file)", source: "mkv"),
         PutioSubtitle(key: "fre-os", language: "French", languageCode: "fre", name: "Interstellar.2014.FR", source: "opensubtitles")]
    }
    func subtitleText(fileID: Int64, key: String) async throws -> String {
        (0..<2700).map { i in
            let start = i * 4
            return "\(i + 1)\n" + String(format: "%02d:%02d:%02d,000 --> %02d:%02d:%02d,000", start / 3600, start / 60 % 60, start % 60,
                                           (start + 3) / 3600, (start + 3) / 60 % 60, (start + 3) % 60) + "\nput.io line \(i + 1)\n"
        }.joined(separator: "\n")
    }
}

struct DemoProvider: SourceProvider {
    let id: String

    func releases(for query: MediaQuery) async throws -> [Release] {
        try await Task.sleep(for: .milliseconds(300 + abs(stableHash(id)) % 900))
        let title = query.searchText.replacingOccurrences(of: " ", with: ".")
        let tag = id == "chill" ? SourceTag(.chill, "TPB") : SourceTag(.direct, id.uppercased())
        let variants: [(String, Int64, Int)] = [
            ("2160p.WEB-DL.DDP5.1.DV.HDR.H.265-FLUX", 18_200_000_000, 412),
            ("1080p.WEBRip.x264.AAC5.1", 2_900_000_000, 1200),
            ("1080p.BluRay.x264-SPARKS", 11_400_000_000, 88),
            ("720p.WEBRip.x264", 1_100_000_000, 6),
        ]
        return variants.enumerated().compactMap { index, variant in
            guard (stableHash(id) + index) % 3 != 0 || id == "chill" else { return nil }
            let hash = String(repeating: String(index), count: 40)
            return Release(name: "\(title).\(variant.0)", link: "magnet:?xt=urn:btih:\(hash)", sizeBytes: variant.1,
                           seeders: variant.2, sources: [tag])
        }
    }
}

struct DemoSubtitles: SubtitleService {
    func search(_ search: SubtitleSearch) async throws -> [SubtitleResult] {
        try await Task.sleep(for: .milliseconds(400))
        return [
            SubtitleResult(fileID: 1, language: search.languages.first ?? "en", release: "Interstellar.2014.1080p.BluRay.x264",
                           downloads: 48_200, trusted: true, hashMatch: true),
            SubtitleResult(fileID: 2, language: search.languages.first ?? "en", release: "Interstellar.2014.IMAX.WEB-DL",
                           downloads: 12_900, hearingImpaired: true),
            SubtitleResult(fileID: 3, language: search.languages.first ?? "en", release: "Interstellar (2014)", downloads: 310,
                           machineTranslated: true),
        ]
    }
    func download(fileID: Int, login: OpenSubtitlesLogin?) async throws -> SubtitleDownload {
        SubtitleDownload(link: URL(string: "https://demo.invalid/\(fileID).srt")!, remaining: 4)
    }
    func text(at link: URL) async throws -> String {
        // A line every 4 seconds for three hours, so any position shows text.
        (0..<2700).map { i in
            "\(i + 1)\n\(Self.clock(i * 4)) --> \(Self.clock(i * 4 + 3))\nDemo subtitle line \(i + 1)\n"
        }.joined(separator: "\n")
    }
    func login(username: String, password: String) async throws -> OpenSubtitlesLogin {
        OpenSubtitlesLogin(token: "demo", allowedDownloads: 20)
    }
    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d,000", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct DemoEpisodeRatings: EpisodeRatingsService {
    func ratings(seriesIMDbID: String, season: Int) async throws -> [Int: EpisodeRating] {
        let scores = [8.1, 8.4, 7.9, 9.3, 8.6, 8.0, 8.8, 9.0]
        return Dictionary(uniqueKeysWithValues: scores.enumerated().map { ($0.offset + 1, EpisodeRating(rating: $0.element, votes: 12_000)) })
    }
}

struct DemoCharts: ChartsService {
    func boxOffice() async throws -> [BoxOfficeEntry] {
        DemoCatalog.movies.prefix(5).enumerated().map { index, item in
            BoxOfficeEntry(rank: index + 1, title: item.title, year: item.year, tmdbID: item.tmdbID, imdbID: nil,
                           revenue: [42_100_000, 18_600_000, 9_400_000, 6_200_000, 3_900_000][index])
        }
    }

    func chart(_ chart: IMDbChart) async throws -> [ChartEntry] {
        let pool = chart.kind == .tv ? DemoCatalog.shows : DemoCatalog.movies
        return pool.enumerated().map { index, item in
            ChartEntry(rank: index + 1, kind: chart.kind, title: item.title, year: item.year, imdbID: "tt\(item.tmdbID)", tmdbID: item.tmdbID)
        }
    }
}

/// chill's combined lists in demo mode: a few of the demo titles, newest first.
struct DemoChill: ChillCatalogService {
    func combinedMovies(allowSettingsSwitch: Bool) async throws -> [ChillTitle] {
        DemoCatalog.movies.reversed().map { ChillTitle(imdbID: nil, title: $0.title, year: $0.year, kind: .movie, source: "DEMO") }
    }
    func combinedShows() async throws -> [ChillTitle] {
        DemoCatalog.shows.map { ChillTitle(imdbID: nil, title: $0.title, year: $0.year, kind: .tv, source: "DEMO") }
    }
}
