import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

private final class FakeSubtitles: SubtitleService, @unchecked Sendable {
    private let lock = NSLock()
    var results: [SubtitleResult] = []
    var resultsForQuery: [SubtitleResult] = []
    var quotaReached = false
    private var searchesStore: [SubtitleSearch] = []
    private var downloadsStore: [(Int, String?)] = []
    var searches: [SubtitleSearch] { lock.withLock { searchesStore } }
    var downloads: [(Int, String?)] { lock.withLock { downloadsStore } }

    func search(_ search: SubtitleSearch) async throws -> [SubtitleResult] {
        lock.withLock { searchesStore.append(search) }
        return search.tmdbID == nil ? resultsForQuery : results
    }
    func download(fileID: Int, login: OpenSubtitlesLogin?) async throws -> SubtitleDownload {
        if quotaReached { throw OpenSubtitlesError.quotaReached }
        lock.withLock { downloadsStore.append((fileID, login?.token)) }
        return SubtitleDownload(link: URL(string: "https://dl.test/\(fileID).srt")!, remaining: 4)
    }
    func text(at link: URL) async throws -> String { "1\n00:00:01,000 --> 00:00:03,000\nHello\n" }
    func login(username: String, password: String) async throws -> OpenSubtitlesLogin {
        guard password == "right" else { throw OpenSubtitlesError.badCredentials }
        return OpenSubtitlesLogin(token: "JWT", allowedDownloads: 20)
    }
}

@MainActor
@Suite struct SubtitleFinderTests {
    static let episode = SubtitleContext(fileID: 77, fileName: "Severance.S02E03.1080p.WEB.mkv", title: "Severance",
                                         tmdbID: 95396, kind: .tv, season: 2, episode: 3)
    static let result = SubtitleResult(fileID: 500, language: "en", release: "Severance.S02E03.WEB", downloads: 10)

    @Test func searchesByShowEpisodeAndHashThenFallsBackToTitle() async {
        let service = FakeSubtitles()
        service.resultsForQuery = [Self.result]
        let finder = SubtitleFinder(context: Self.episode, service: service, store: LocalStore(fileURL: nil),
                                    cache: SubtitleFileCache(directory: nil), language: "pt", hasher: { "abc123" })
        await finder.search()
        #expect(finder.results == [Self.result])
        #expect(service.searches.count == 2)
        #expect(service.searches[0] == SubtitleSearch(tmdbID: 95396, kind: .tv, season: 2, episode: 3, query: nil,
                                                      languages: ["pt-pt"], movieHash: "abc123"))
        #expect(service.searches[1].query == "Severance")
    }

    @Test func choosingDownloadsOnceRemembersAndRestores() async {
        let service = FakeSubtitles()
        let store = LocalStore(fileURL: nil)
        let cache = SubtitleFileCache(directory: nil)
        let finder = SubtitleFinder(context: Self.episode, service: service, store: store, cache: cache, language: "en",
                                    session: { OpenSubtitlesLogin(token: "JWT", allowedDownloads: 20) })
        await finder.choose(Self.result)
        #expect(finder.text(at: 2) == "Hello")
        #expect(finder.remainingDownloads == 4)
        #expect(service.downloads.map(\.1) == ["JWT"])
        await finder.shiftTiming(by: 0.5)
        #expect(finder.text(at: 1.2) == nil)
        #expect(finder.text(at: 3.4) == "Hello")

        // Next time this file plays: restored from disk, no new download.
        let again = SubtitleFinder(context: Self.episode, service: service, store: store, cache: cache, language: "en")
        await again.restore()
        #expect(again.choice?.offset == 0.5)
        #expect(again.text(at: 2) == "Hello")
        await again.choose(Self.result)
        #expect(service.downloads.count == 1)

        await again.turnOff()
        #expect(again.text(at: 2) == nil)
        #expect(await store.snapshot.subtitleChoices[77] == nil)
    }

    @Test func quotaAndMissingKeyExplainThemselves() async {
        let service = FakeSubtitles()
        service.quotaReached = true
        let finder = SubtitleFinder(context: Self.episode, service: service, store: LocalStore(fileURL: nil),
                                    cache: SubtitleFileCache(directory: nil), language: "en")
        await finder.choose(Self.result)
        #expect(finder.message?.contains("Sign in to OpenSubtitles") == true)
        #expect(finder.track == nil)

        let noKey = SubtitleFinder(context: Self.episode, service: nil, store: LocalStore(fileURL: nil),
                                   cache: SubtitleFileCache(directory: nil), language: "en")
        await noKey.search()
        #expect(noKey.message?.contains("API key") == true)
    }

    @Test func appModelSignsInAndUsesBundledKey() async throws {
        let service = FakeSubtitles()
        let tokens = InMemoryTokenStore()
        let factory = ServiceFactory(makePutio: { _ in fatalError() }, makeCatalog: { _ in FakeCatalog() },
                                     makeProvider: { _, _ in nil }, makeSubtitles: { _ in service })
        let app = AppModel(tokens: tokens, store: LocalStore(fileURL: nil), factory: factory, bundledOpenSubtitlesKey: " key ")
        #expect(app.hasSubtitleSearch)
        #expect(app.usesBundledOpenSubtitles)
        await #expect(throws: OpenSubtitlesError.badCredentials) {
            _ = try await app.signInToOpenSubtitles(username: "me", password: "wrong")
        }
        #expect(app.openSubtitlesUser == nil)
        _ = try await app.signInToOpenSubtitles(username: "me", password: "right")
        #expect(app.openSubtitlesUser == "me")
        #expect(tokens.read(.opensubtitlesPassword) == "right")
        app.signOutOfOpenSubtitles()
        #expect(tokens.read(.opensubtitlesUsername) == nil)
    }
}
