import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@MainActor @Suite struct OfflineSubtitlesTests {
    func makeApp(_ putio: FakePutio, store: LocalStore, defaults: UserDefaults = testDefaults()) -> AppModel {
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in FakeCatalog() }, makeProvider: { _, _ in nil })
        return AppModel(tokens: InMemoryTokenStore([.putio: "p", .tmdb: "t"]), defaults: defaults, store: store, factory: factory)
    }

    static let tracks = [PutioSubtitle(key: "fa1", language: "Persian", languageCode: "per", source: "folder"),
                         PutioSubtitle(key: "en1", language: "English", languageCode: "eng", source: "mkv")]

    @Test func downloadingTurnsOnPutiosFirstSubtitle() async {
        let putio = FakePutio()
        putio.subtitleTracks = Self.tracks
        let store = LocalStore(fileURL: nil)
        let app = makeApp(putio, store: store)
        await app.cachePutioSubtitles(fileID: 7)
        #expect(await store.snapshot.subtitleChoices[7]?.putioKey == "fa1")
    }

    @Test func prefersTheLanguageFromSettings() async {
        let putio = FakePutio()
        putio.subtitleTracks = Self.tracks
        let store = LocalStore(fileURL: nil)
        let app = makeApp(putio, store: store)
        var settings = app.settings
        settings.subtitleLanguage = "en"
        app.updateSettings(settings)
        await app.cachePutioSubtitles(fileID: 7)
        #expect(await store.snapshot.subtitleChoices[7]?.putioKey == "en1")
    }

    @Test func keepsWhatTheUserAlreadyPicked() async {
        let putio = FakePutio()
        putio.subtitleTracks = Self.tracks
        let store = LocalStore(fileURL: nil)
        await store.update { $0.subtitleChoices[7] = .off }
        await makeApp(putio, store: store).cachePutioSubtitles(fileID: 7)
        #expect(await store.snapshot.subtitleChoices[7]?.isOff == true)
    }

    @Test func noSubtitlesNoChoice() async {
        let store = LocalStore(fileURL: nil)
        await makeApp(FakePutio(), store: store).cachePutioSubtitles(fileID: 7)
        #expect(await store.snapshot.subtitleChoices[7] == nil)
    }
}
