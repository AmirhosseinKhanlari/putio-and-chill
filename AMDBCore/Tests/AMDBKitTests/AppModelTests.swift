import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

final class ProviderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func record(_ id: String) { lock.withLock { ids.append(id) } }
    func reset() { lock.withLock { ids.removeAll() } }
    var all: [String] { lock.withLock { ids } }
}

@MainActor @Suite struct AppModelTests {
    func makeModel(_ tokens: [TokenKey: String], calls: ProviderCalls = ProviderCalls(), catalog: FakeCatalog = FakeCatalog(),
                   putio: FakePutio = FakePutio(), defaults: UserDefaults = testDefaults()) -> AppModel {
        let factory = ServiceFactory(
            makePutio: { _ in putio },
            makeCatalog: { _ in catalog },
            makeProvider: { config in
                calls.record(config.id)
                return FakeProvider(id: config.id)
            })
        return AppModel(tokens: InMemoryTokenStore(tokens), defaults: defaults, store: LocalStore(fileURL: nil), factory: factory)
    }

    @Test func notReadyWithoutTokens() {
        let model = makeModel([:])
        #expect(!model.isReady)
        #expect(model.putio == nil)
    }

    @Test func readyWithPutioAndTMDB() {
        let model = makeModel([.putio: "p", .tmdb: "t"])
        #expect(model.isReady)
    }

    @Test func settingTokensRebuilds() {
        let model = makeModel([:])
        model.setToken("p", for: .putio)
        model.setToken("t", for: .tmdb)
        #expect(model.isReady)
        #expect(model.token(.putio) == "p")
        model.setToken(nil, for: .putio)
        #expect(!model.isReady)
    }

    @Test func providersFollowSettings() {
        let calls = ProviderCalls()
        let model = makeModel([.putio: "p", .tmdb: "t"], calls: calls)
        #expect(calls.all == ["yts", "eztv", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
        calls.reset()
        var settings = model.settings
        settings.sources[1].enabled = false
        model.updateSettings(settings)
        #expect(calls.all == ["yts", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
    }

    /// Someone who searched chill alone: chill is gone and the default sources search instead.
    @Test func settingsWithOnlyChillSearchTheDefaultSources() {
        let defaults = testDefaults()
        defaults.set(SettingsAndTokensTests.savedWithChill(chillEnabled: true, othersEnabled: false), forKey: AppSettings.storageKey)
        let calls = ProviderCalls()
        let model = makeModel([.putio: "p", .tmdb: "t"], calls: calls, defaults: defaults)
        #expect(calls.all == ["yts", "eztv", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
        #expect(model.settings.source("chill") == nil)
    }

    @Test func nothingAboutChillIsLeftOnTheModel() {
        let model = makeModel([.putio: "p", .tmdb: "t"])
        let names = Mirror(reflecting: model).children.compactMap(\.label).map { $0.lowercased() }
        #expect(!names.isEmpty)
        #expect(!names.contains { $0.contains("chill") })
    }

    @Test func validateTMDBUsesFactory() async {
        var failing = FakeCatalog()
        failing.failAll = true
        let model = makeModel([:], catalog: failing)
        await #expect(throws: AppError.self) { try await model.validateTMDB("bad") }
    }

    @Test func completedHashesComeFromPutioTransfers() async {
        let putio = FakePutio()
        putio.setTransfer(PutioTransfer(id: 1, status: "COMPLETED", hash: "ABC"))
        putio.setTransfer(PutioTransfer(id: 2, status: "DOWNLOADING", hash: "def"))
        let model = makeModel([.putio: "p", .tmdb: "t"], putio: putio)
        #expect(await model.completedHashes() == ["abc"])
    }

    @Test func notePlayedPersists() async {
        let model = makeModel([.putio: "p", .tmdb: "t"])
        await model.notePlayed(PlayedTitle(tmdbID: 3, kind: .movie, title: "Heat"))
        #expect(await model.store.snapshot.lastPlayed?.tmdbID == 3)
    }
}
