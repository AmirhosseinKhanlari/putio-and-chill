import AMDBCore
import Foundation
import Observation

public struct ServiceFactory: Sendable {
    public var makePutio: @Sendable (String) -> any PutioService
    public var makeCatalog: @Sendable (String) -> any CatalogService
    public var makeProvider: @Sendable (SourceConfig, _ chillToken: String?) -> (any SourceProvider)?
    public var makeRatings: @Sendable (String) -> any RatingsService

    public init(makePutio: @escaping @Sendable (String) -> any PutioService,
                makeCatalog: @escaping @Sendable (String) -> any CatalogService,
                makeProvider: @escaping @Sendable (SourceConfig, String?) -> (any SourceProvider)?,
                makeRatings: @escaping @Sendable (String) -> any RatingsService = {
                    RatingsClient(apiKey: $0, transport: URLSessionTransport())
                }) {
        self.makePutio = makePutio
        self.makeCatalog = makeCatalog
        self.makeProvider = makeProvider
        self.makeRatings = makeRatings
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
            makeRatings: { RatingsClient(apiKey: $0, transport: transport) })
    }()
}

@Observable @MainActor
public final class AppModel {
    public private(set) var putio: (any PutioService)?
    public private(set) var catalog: (any CatalogService)?
    public private(set) var settings: AppSettings
    public private(set) var hasChill = false
    public private(set) var hasRatings = false
    /// True when the app ships a TMDB token, so users never have to enter one.
    public let usesBundledTMDB: Bool
    public let library: LibraryIndex
    public let transfers: TransferMonitor
    public let store: LocalStore

    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let factory: ServiceFactory
    @ObservationIgnored private var searcher: any ReleaseSearching = ReleaseAggregator(providers: [])
    @ObservationIgnored private var ratingsService: (any RatingsService)?
    @ObservationIgnored private let bundledTMDBToken: String?
    @ObservationIgnored private let ratingsCache: RatingsCache

    public init(tokens: any TokenStore, defaults: UserDefaults = .standard, store: LocalStore, factory: ServiceFactory = .live,
                bundledTMDBToken: String? = nil, ratingsCache: RatingsCache = RatingsCache(fileURL: nil)) {
        self.tokens = tokens
        self.userDefaults = defaults
        self.store = store
        self.factory = factory
        let bundled = bundledTMDBToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundledTMDBToken = (bundled?.isEmpty ?? true) ? nil : bundled
        self.usesBundledTMDB = self.bundledTMDBToken != nil
        self.ratingsCache = ratingsCache
        settings = AppSettings.load(from: defaults)
        library = LibraryIndex(store: store)
        transfers = TransferMonitor(store: store)
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

    public func validateTMDB(_ token: String) async throws {
        try await factory.makeCatalog(token).validate()
    }

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
        hasRatings = ratingsService != nil
        let chillToken = tokens.read(.chill)
        hasChill = chillToken != nil
        let providers = settings.sources.filter(\.enabled).compactMap { factory.makeProvider($0, chillToken) }
        searcher = ReleaseAggregator(providers: providers)
        library.configure(putio: putio, catalog: catalog)
        transfers.configure(putio: putio, library: library)
    }
}
