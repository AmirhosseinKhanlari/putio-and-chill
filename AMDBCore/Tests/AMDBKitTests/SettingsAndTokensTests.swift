import Foundation
import Testing
@testable import AMDBKit

@Suite struct SettingsAndTokensTests {
    @Test func defaultsIncludeAllSources() {
        #expect(AppSettings.defaults.sources.map(\.id) == ["chill", "yts", "eztv", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
        #expect(AppSettings.defaults.source("yts")?.baseURL == "https://movies-api.accel.li")
        #expect(AppSettings.defaults.autoPlayCountdown)
    }

    @Test func roundTripsThroughUserDefaults() {
        let defaults = testDefaults()
        var settings = AppSettings.defaults
        settings.autoPlayCountdown = false
        settings.sources[1].enabled = false
        settings.defaultResolution = 1080
        settings.save(to: defaults)
        #expect(AppSettings.load(from: defaults) == settings)
    }

    @Test func subtitleStyleRoundTripsAndToleratesUnknownValues() throws {
        let defaults = testDefaults()
        var settings = AppSettings.defaults
        settings.subtitleStyle = SubtitleStyle(size: .large, background: .solid, color: .yellow, typeface: .rounded)
        settings.save(to: defaults)
        #expect(AppSettings.load(from: defaults).subtitleStyle == settings.subtitleStyle)

        let odd = #"{"size":"huge","background":"none","color":"white"}"#
        let decoded = try JSONDecoder().decode(SubtitleStyle.self, from: Data(odd.utf8))
        #expect(decoded == SubtitleStyle(size: .medium, background: .none, color: .white, typeface: .standard))
        #expect(AppSettings.defaults.subtitleStyle == .standard)
    }

    @Test func loadAddsNewlyIntroducedSources() {
        let defaults = testDefaults()
        var settings = AppSettings.defaults
        settings.sources.removeAll { $0.id == "knaben" }
        settings.save(to: defaults)
        #expect(AppSettings.load(from: defaults).source("knaben") != nil)
    }

    @Test func settingsSavedBeforeTorrentGalaxyGetItTurnedOn() {
        let defaults = testDefaults()
        var settings = AppSettings.defaults
        settings.sources.removeAll { $0.id == "torrentgalaxy" }
        settings.sources[1].enabled = false
        settings.save(to: defaults)
        let loaded = AppSettings.load(from: defaults)
        #expect(loaded.sources.last == SourceConfig(id: "torrentgalaxy", name: "TorrentGalaxy", enabled: true,
                                                    baseURL: "https://torrentgalaxy.info"))
        #expect(loaded.source("yts")?.enabled == false)
    }

    @Test func inMemoryTokens() {
        let tokens = InMemoryTokenStore()
        tokens.write("a", for: .putio)
        #expect(tokens.read(.putio) == "a")
        tokens.write(nil, for: .putio)
        #expect(tokens.read(.putio) == nil)
    }

    @Test func onlyPutioStaysOnDevice() {
        #expect(!TokenKey.putio.synchronizes)
        #expect(TokenKey.tmdb.synchronizes)
        #expect(TokenKey.chill.synchronizes)
    }
}
