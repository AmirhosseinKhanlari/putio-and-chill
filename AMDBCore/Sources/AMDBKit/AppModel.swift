import AMDBCore
import Foundation
import Observation

public struct ServiceFactory: Sendable {
    public var makePutio: @Sendable (String) -> any PutioService
    public var makeCatalog: @Sendable (String) -> any CatalogService
    public var makeProvider: @Sendable (SourceConfig, _ chillToken: String?) -> (any SourceProvider)?
    public var makeRatings: @Sendable (String) -> any RatingsService
    public var makeCharts: @Sendable (String) -> any ChartsService
    public var trailers: any TrailerService
    public var episodeRatings: any EpisodeRatingsService
    public var makeSubtitles: @Sendable (String) -> any SubtitleService
    public var makeChillCatalog: @Sendable (String) -> any ChillCatalogService
    /// Latest movie / show lists that need no account (MyMoviz).
    public var latestLists: [any LatestTitlesSource]

    public init(makePutio: @escaping @Sendable (String) -> any PutioService,
                makeCatalog: @escaping @Sendable (String) -> any CatalogService,
                makeProvider: @escaping @Sendable (SourceConfig, String?) -> (any SourceProvider)?,
                makeRatings: @escaping @Sendable (String) -> any RatingsService = {
                    RatingsClient(apiKey: $0, transport: URLSessionTransport())
                },
                makeCharts: @escaping @Sendable (String) -> any ChartsService = {
                    TraktClient(clientID: $0, transport: URLSessionTransport())
                },
                trailers: any TrailerService = IMDbTrailerClient(transport: URLSessionTransport()),
                episodeRatings: any EpisodeRatingsService = IMDbEpisodeRatingsClient(transport: URLSessionTransport()),
                makeSubtitles: @escaping @Sendable (String) -> any SubtitleService = {
                    OpenSubtitlesClient(apiKey: $0, transport: URLSessionTransport())
                },
                makeChillCatalog: @escaping @Sendable (String) -> any ChillCatalogService = {
                    ChillCatalogClient(token: $0, transport: URLSessionTransport())
                },
                latestLists: [any LatestTitlesSource] = [MyMovizClient(kind: .movie, transport: URLSessionTransport()),
                                                         MyMovizClient(kind: .tv, transport: URLSessionTransport())]) {
        self.makePutio = makePutio
        self.makeCatalog = makeCatalog
        self.makeProvider = makeProvider
        self.makeRatings = makeRatings
        self.makeCharts = makeCharts
        self.trailers = trailers
        self.episodeRatings = episodeRatings
        self.makeSubtitles = makeSubtitles
        self.makeChillCatalog = makeChillCatalog
        self.latestLists = latestLists
    }

    public static let live: ServiceFactory = {
        let transport = URLSessionTransport()
        return ServiceFactory(
            makePutio: { PutioClient(token: $0, transport: transport) },
            makeCatalog: { CatalogClient(accessToken: $0, transport: transport) },
            makeProvider: { config, chillToken in
                guard let url = URL(string: config.baseURL) else { return nil }
                switch config.id {
                case "chill": return chillToken.map { ChillProvider(token: $0, transport: transport, baseURL: url) }
                case "yts": return YTSProvider(baseURL: url, transport: transport)
                case "eztv": return EZTVProvider(baseURL: url, transport: transport)
                case "apibay": return ApibayProvider(baseURL: url, transport: transport)
                case "knaben": return KnabenProvider(baseURL: url, transport: transport)
                case "torrentscsv": return TorrentsCSVProvider(baseURL: url, transport: transport)
                default: return nil
                }
            },
            makeRatings: { RatingsClient(apiKey: $0, transport: transport) },
            makeCharts: { TraktClient(clientID: $0, transport: transport) },
            trailers: IMDbTrailerClient(transport: transport),
            episodeRatings: IMDbEpisodeRatingsClient(transport: transport),
            makeSubtitles: { OpenSubtitlesClient(apiKey: $0, transport: transport) })
    }()
}

@Observable @MainActor
public final class AppModel {
    public private(set) var putio: (any PutioService)?
    public private(set) var catalog: (any CatalogService)?
    public private(set) var settings: AppSettings
    public private(set) var hasChill = false
    public private(set) var hasRatings = false
    /// OpenSubtitles search is available (built-in or user API key).
    public private(set) var hasSubtitleSearch = false
    /// True when the app ships an OpenSubtitles API key.
    public let usesBundledOpenSubtitles: Bool
    /// Signed-in OpenSubtitles username, if any.
    public private(set) var openSubtitlesUser: String?
    /// Account level and daily limit from the last sign-in this session.
    public var openSubtitlesAccount: OpenSubtitlesLogin? { openSubtitlesLogin }
    /// True when the app ships a TMDB token, so users never have to enter one.
    public let usesBundledTMDB: Bool
    /// IMDb Top 250 charts are available (a Trakt client ID is built in).
    public var hasCharts: Bool { chartsService != nil }
    public let library: LibraryIndex
    public let transfers: TransferMonitor
    public let store: LocalStore
    public let myList: MyList
    public let downloads: DownloadsIndex
    /// "Latest on chill" rows (needs a connected chill account).
    public let chillFeed: ChillFeed

    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let factory: ServiceFactory
    @ObservationIgnored private var searcher: any ReleaseSearching = ReleaseAggregator(providers: [])
    @ObservationIgnored private var ratingsService: (any RatingsService)?
    @ObservationIgnored private let bundledTMDBToken: String?
    @ObservationIgnored private let ratingsCache: RatingsCache
    @ObservationIgnored private let chartsService: (any ChartsService)?
    @ObservationIgnored private var chartCache: [IMDbChart: [ChartEntry]] = [:]
    @ObservationIgnored private var episodeRatingsCache: [String: [Int: EpisodeRating]] = [:]
    @ObservationIgnored private var subtitleService: (any SubtitleService)?
    @ObservationIgnored private var chillCatalog: (any ChillCatalogService)?
    @ObservationIgnored private let bundledOpenSubtitlesKey: String?
    @ObservationIgnored private var openSubtitlesLogin: OpenSubtitlesLogin?
    @ObservationIgnored private let subtitleCache: SubtitleFileCache

    public init(tokens: any TokenStore, defaults: UserDefaults = .standard, store: LocalStore, factory: ServiceFactory = .live,
                bundledTMDBToken: String? = nil, ratingsCache: RatingsCache = RatingsCache(fileURL: nil),
                bundledTraktClientID: String? = nil, bundledOpenSubtitlesKey: String? = nil,
                subtitleCache: SubtitleFileCache = SubtitleFileCache(directory: nil),
                libraryCache: LibraryCache = LibraryCache(fileURL: nil), chillFeedURL: URL? = nil) {
        self.tokens = tokens
        self.userDefaults = defaults
        self.store = store
        self.factory = factory
        let bundled = bundledTMDBToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundledTMDBToken = (bundled?.isEmpty ?? true) ? nil : bundled
        self.usesBundledTMDB = self.bundledTMDBToken != nil
        self.ratingsCache = ratingsCache
        let subtitlesKey = bundledOpenSubtitlesKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundledOpenSubtitlesKey = (subtitlesKey?.isEmpty ?? true) ? nil : subtitlesKey
        self.usesBundledOpenSubtitles = self.bundledOpenSubtitlesKey != nil
        self.subtitleCache = subtitleCache
        let trakt = bundledTraktClientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chartsService = (trakt?.isEmpty ?? true) ? nil : trakt.map(factory.makeCharts)
        settings = AppSettings.load(from: defaults)
        library = LibraryIndex(store: store, cache: libraryCache)
        transfers = TransferMonitor(store: store)
        myList = MyList(store: store)
        downloads = DownloadsIndex(store: store)
        chillFeed = ChillFeed(fileURL: chillFeedURL)
        rebuild()
    }

    public var isReady: Bool { putio != nil && catalog != nil }
    public var releaseSearcher: any ReleaseSearching { searcher }

    public func token(_ key: TokenKey) -> String? { tokens.read(key) }

    public func setToken(_ value: String?, for key: TokenKey) {
        tokens.write(value, for: key)
        rebuild()
    }

    public func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        newSettings.save(to: userDefaults)
        rebuild()
    }

    /// Updates the library from put.io when automatic updates are on and it's older than the chosen interval
    /// (or always, when `force`). Returns whether it ran.
    @discardableResult
    public func refreshLibraryIfDue(force: Bool = false, now: Date = Date()) async -> Bool {
        guard putio != nil else { return false }
        let due = library.isStale(maxAge: TimeInterval(settings.libraryUpdateMinutes * 60), now: now)
        guard force || (settings.libraryAutoUpdate && due) || library.lastUpdated == nil else { return false }
        await library.refresh()
        return true
    }

    /// What "Organize library" would move, using `layout` (the Settings being edited).
    public func planOrganize(layout: FolderLayout) async throws -> OrganizePlan {
        guard let putio else { throw AppError.unauthorized(service: "putio") }
        if library.folderTree.isEmpty { await library.refresh() }
        return try await LibraryOrganizer.plan(entries: library.entries, layout: layout, putio: putio, store: store,
                                               tree: library.folderTree)
    }

    /// Moves the planned items, then re-reads the library so the new locations show up. Returns how many moved.
    public func applyOrganize(_ plan: OrganizePlan, layout: FolderLayout) async throws -> Int {
        guard let putio else { throw AppError.unauthorized(service: "putio") }
        let moved = try await LibraryOrganizer.apply(plan, layout: layout, putio: putio, store: store)
        await library.refresh()
        return moved
    }

    /// Saves the subtitle look without rebuilding services (safe mid-playback).
    public func updateSubtitleStyle(_ style: SubtitleStyle) {
        settings.subtitleStyle = style
        settings.save(to: userDefaults)
    }

    public func validateTMDB(_ token: String) async throws {
        try await factory.makeCatalog(token).validate()
    }

    /// Searches every source, picks by the Smart Get rule, and sends the winner to put.io.
    public func smartGet(_ query: MediaQuery, target: TransferTarget) async -> SmartGetResult {
        var latest = ReleaseSnapshot()
        for await snapshot in searcher.stream(for: query) {
            latest = snapshot
            if snapshot.isComplete { break }
        }
        guard let release = SmartPicker.pick(latest.releases, rule: settings.smartGet) else { return .noMatch }
        do {
            try await transfers.send(release, target: target)
            return .sent(release)
        } catch let error as AppError {
            return .failed(error)
        } catch {
            return .failed(.transport(error.localizedDescription))
        }
    }

    /// Test seam: replace the release searcher built from settings.
    func overrideReleaseSearcher(_ searcher: any ReleaseSearching) { self.searcher = searcher }

    public func validateMDBList(_ key: String) async throws {
        try await factory.makeRatings(key).validate()
    }

    /// IMDb / Rotten Tomatoes scores, served from the on-device cache when fresh. Nil without an MDBList key or on failure.
    public func ratings(imdbID: String, kind: MediaKind) async -> Ratings? {
        guard let ratingsService else { return nil }
        if let cached = await ratingsCache.fresh(imdbID) { return cached }
        guard let fetched = try? await ratingsService.ratings(imdbID: imdbID, kind: kind) else { return nil }
        await ratingsCache.store(fetched, for: imdbID)
        return fetched
    }

    /// IMDb chart entries, fetched once per app session.
    public func chart(_ chart: IMDbChart) async throws -> [ChartEntry] {
        if let cached = chartCache[chart] { return cached }
        guard let chartsService else { return [] }
        let entries = try await chartsService.chart(chart)
        chartCache[chart] = entries
        return entries
    }

    /// Last weekend's box office (Trakt); empty without a Trakt client ID.
    public func boxOffice() async throws -> [BoxOfficeEntry] {
        guard let chartsService else { return [] }
        return try await chartsService.boxOffice()
    }

    /// A natively playable trailer from IMDb, or nil (caller falls back to YouTube).
    public func trailer(imdbID: String) async -> TrailerVideo? {
        try? await factory.trailers.trailer(imdbID: imdbID)
    }

    /// IMDb score per episode for one season, cached for the app session. Empty on failure.
    public func episodeRatings(seriesIMDbID: String, season: Int) async -> [Int: EpisodeRating] {
        let key = "\(seriesIMDbID)-\(season)"
        if let cached = episodeRatingsCache[key] { return cached }
        guard let fetched = try? await factory.episodeRatings.ratings(seriesIMDbID: seriesIMDbID, season: season) else { return [:] }
        if !fetched.isEmpty { episodeRatingsCache[key] = fetched }
        return fetched
    }

    /// Subtitle search for one video, wired to the signed-in OpenSubtitles account and the file's hash.
    /// `includePutio` false: put.io's tracks are left to the player (Apple TV shows them in its own menu).
    public func subtitleFinder(for context: SubtitleContext, fileSize: Int64?, includePutio: Bool = true) -> SubtitleFinder {
        let language = settings.subtitleLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"
        let putio = putio
        let hasher: (@Sendable () async -> String?)? = putio.flatMap { putio in
            guard let size = fileSize else { return nil }
            return {
                guard let url = try? await putio.originalURL(fileID: context.fileID) else { return nil }
                return try? await OpenSubtitlesHash.compute(url: url, size: size, transport: URLSessionTransport())
            }
        }
        let source = putio.flatMap { putio in includePutio ? putio : nil }.map { putio in
            PutioSubtitleSource(list: { try await putio.subtitles(fileID: context.fileID) },
                                text: { try await putio.subtitleText(fileID: context.fileID, key: $0) })
        }
        return SubtitleFinder(context: context, service: subtitleService, putio: source, store: store, cache: subtitleCache,
                              language: language, preferredLanguage: settings.subtitleLanguage,
                              signedIn: openSubtitlesUser != nil, session: { [weak self] in await self?.openSubtitlesSession() },
                              hasher: hasher)
    }

    /// Saves put.io's subtitles for a file on the device (offline copies play them without a connection).
    public func cachePutioSubtitles(fileID: Int64) async {
        guard let putio, let tracks = try? await putio.subtitles(fileID: fileID) else { return }
        subtitleCache.writePutioList(tracks, fileID: fileID)
        for track in tracks where subtitleCache.readPutio(fileID: fileID, key: track.key) == nil {
            if let text = try? await putio.subtitleText(fileID: fileID, key: track.key) {
                subtitleCache.writePutio(text, fileID: fileID, key: track.key)
            }
        }
        // A downloaded video comes with its subtitle switched on: the preferred language from Settings when put.io
        // has it, else put.io's first subtitle. A pick the user already made for this file (including Off) stays.
        guard await store.snapshot.subtitleChoices[fileID] == nil else { return }
        let saved = tracks.filter { subtitleCache.readPutio(fileID: fileID, key: $0.key) != nil }
        guard let pick = settings.subtitleLanguage.flatMap({ SubtitleFinder.bestTrack(saved, for: $0) }) ?? saved.first else { return }
        let choice = SubtitleFinder.choice(for: pick)
        await store.update { $0.subtitleChoices[fileID] = choice }
    }

    /// Signs in to OpenSubtitles and remembers the account in the Keychain.
    public func signInToOpenSubtitles(username: String, password: String) async throws -> OpenSubtitlesLogin {
        guard let subtitleService else { throw OpenSubtitlesError.badCredentials }
        let login = try await subtitleService.login(username: username, password: password)
        tokens.write(username, for: .opensubtitlesUsername)
        tokens.write(password, for: .opensubtitlesPassword)
        openSubtitlesUser = username
        openSubtitlesLogin = login
        return login
    }

    public func signOutOfOpenSubtitles() {
        tokens.write(nil, for: .opensubtitlesUsername)
        tokens.write(nil, for: .opensubtitlesPassword)
        openSubtitlesUser = nil
        openSubtitlesLogin = nil
    }

    /// Signed-in session for downloads; signs in again with the saved account when needed. Nil when signed out.
    private func openSubtitlesSession() async -> OpenSubtitlesLogin? {
        if let openSubtitlesLogin { return openSubtitlesLogin }
        guard let subtitleService, let username = tokens.read(.opensubtitlesUsername),
              let password = tokens.read(.opensubtitlesPassword),
              let login = try? await subtitleService.login(username: username, password: password) else { return nil }
        openSubtitlesLogin = login
        return login
    }

    /// Combined latest lists (chill when connected, plus MyMoviz) for the Movies / TV Shows tabs;
    /// at most every six hours unless forced.
    public func refreshChillFeed(force: Bool = false) async {
        await chillFeed.load(service: chillCatalog, extra: factory.latestLists, catalog: catalog, force: force)
    }

    public func notePlayed(_ title: PlayedTitle) async {
        await store.update { $0.lastPlayed = title }
    }

    /// Lowercased infohashes of finished put.io transfers, used to pin "already in put.io" versions.
    public func completedHashes() async -> Set<String> {
        guard let putio, let transfers = try? await putio.transfers() else { return [] }
        return Set(transfers.compactMap { transfer in
            guard case .completed = TransferPhase(transfer) else { return nil }
            return transfer.hash?.lowercased()
        })
    }

    private func rebuild() {
        putio = tokens.read(.putio).map(factory.makePutio)
        catalog = (tokens.read(.tmdb) ?? bundledTMDBToken).map(factory.makeCatalog)
        ratingsService = tokens.read(.mdblist).map(factory.makeRatings)
        subtitleService = (tokens.read(.opensubtitles) ?? bundledOpenSubtitlesKey).map(factory.makeSubtitles)
        hasSubtitleSearch = subtitleService != nil
        openSubtitlesUser = tokens.read(.opensubtitlesUsername)
        openSubtitlesLogin = nil
        hasRatings = ratingsService != nil
        let chillToken = tokens.read(.chill)
        hasChill = chillToken != nil
        chillCatalog = chillToken.map(factory.makeChillCatalog)
        let providers = settings.sources.filter(\.enabled).compactMap { factory.makeProvider($0, chillToken) }
        searcher = ReleaseAggregator(providers: providers)
        library.configure(putio: putio, catalog: catalog)
        transfers.configure(putio: putio, library: library)
        transfers.layout = FolderLayout(settings: settings)
    }
}
