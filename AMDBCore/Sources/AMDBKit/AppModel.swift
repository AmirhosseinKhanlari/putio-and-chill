import AMDBCore
import Foundation
import Observation

public struct ServiceFactory: Sendable {
    public var makePutio: @Sendable (String) -> any PutioService
    public var makeCatalog: @Sendable (String) -> any CatalogService
    public var makeProvider: @Sendable (SourceConfig, _ chillToken: String?) -> (any SourceProvider)?

    public init(makePutio: @escaping @Sendable (String) -> any PutioService,
                makeCatalog: @escaping @Sendable (String) -> any CatalogService,
                makeProvider: @escaping @Sendable (SourceConfig, String?) -> (any SourceProvider)?) {
        self.makePutio = makePutio
        self.makeCatalog = makeCatalog
        self.makeProvider = makeProvider
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
                default: return nil
                }
            })
    }()
}

@Observable @MainActor
public final class AppModel {
    public private(set) var putio: (any PutioService)?
    public private(set) var catalog: (any CatalogService)?
    public private(set) var settings: AppSettings
    public private(set) var hasChill = false
    public let library: LibraryIndex
    public let transfers: TransferMonitor
    public let store: LocalStore

    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let factory: ServiceFactory
    @ObservationIgnored private var searcher: any ReleaseSearching = ReleaseAggregator(providers: [])

    public init(tokens: any TokenStore, defaults: UserDefaults = .standard, store: LocalStore, factory: ServiceFactory = .live) {
        self.tokens = tokens
        self.userDefaults = defaults
        self.store = store
        self.factory = factory
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
        catalog = tokens.read(.tmdb).map(factory.makeCatalog)
        let chillToken = tokens.read(.chill)
        hasChill = chillToken != nil
        let providers = settings.sources.filter(\.enabled).compactMap { factory.makeProvider($0, chillToken) }
        searcher = ReleaseAggregator(providers: providers)
        library.configure(putio: putio, catalog: catalog)
        transfers.configure(putio: putio, library: library)
    }
}
