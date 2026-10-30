import Foundation
import Testing
@testable import AMDBKit

@Suite struct SettingsAndTokensTests {
    @Test func defaultsIncludeAllSources() {
        #expect(AppSettings.defaults.sources.map(\.id) == ["yts", "eztv", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
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
        settings.sources[0].enabled = false
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
        #expect(TokenKey.mdblist.synchronizes)
    }

    @Test func noChillTokenKeyRemains() {
        #expect(!TokenKey.allCases.map(\.rawValue).contains("chill"))
    }

    /// Settings saved by a version that had chill as a release source.
    static func savedWithChill(chillEnabled: Bool, othersEnabled: Bool, customYTS: String = "https://movies-api.accel.li") -> Data {
        let others = [("yts", "YTS", customYTS), ("eztv", "EZTV", "https://eztvx.to"), ("apibay", "The Pirate Bay (apibay)", "https://apibay.org"),
                      ("knaben", "Knaben", "https://api.knaben.org"), ("torrentscsv", "Torrents.csv", "https://torrents-csv.com"),
                      ("torrentgalaxy", "TorrentGalaxy", "https://torrentgalaxy.info")]
            .map { #"{"id":"\#($0.0)","name":"\#($0.1)","enabled":\#(othersEnabled),"baseURL":"\#($0.2)"}"# }
        let chill = #"{"id":"chill","name":"chill","enabled":\#(chillEnabled),"baseURL":"https://api.example.invalid/v4"}"#
        return Data(#"{"sources":[\#(([chill] + others).joined(separator: ","))],"autoPlayCountdown":false}"#.utf8)
    }

    @Test func chillSourceIsDroppedFromSavedSettings() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Self.savedWithChill(chillEnabled: true, othersEnabled: true))
        #expect(decoded.sources.map(\.id) == ["yts", "eztv", "apibay", "knaben", "torrentscsv", "torrentgalaxy"])
        #expect(decoded.sources.allSatisfy { $0.enabled })
        #expect(!decoded.autoPlayCountdown, "the other settings are kept")
    }

    @Test func onlyChillEnabledTurnsTheDefaultSourcesBackOn() throws {
        let data = Self.savedWithChill(chillEnabled: true, othersEnabled: false, customYTS: "https://yts.example.org")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.source("chill") == nil)
        #expect(decoded.sources.allSatisfy { $0.enabled }, "a search still finds releases")
        #expect(decoded.source("yts")?.baseURL == "https://yts.example.org", "edited addresses are kept")
    }

    @Test func everythingSwitchedOffStaysOff() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Self.savedWithChill(chillEnabled: false, othersEnabled: false))
        #expect(decoded.source("chill") == nil)
        #expect(!decoded.sources.contains { $0.enabled }, "the user turned every source off, chill included")
    }

    @Test func someSourcesStillOnAreLeftAsTheyWere() throws {
        var json = String(decoding: Self.savedWithChill(chillEnabled: true, othersEnabled: false), as: UTF8.self)
        json = json.replacingOccurrences(of: #""id":"eztv","name":"EZTV","enabled":false"#, with: #""id":"eztv","name":"EZTV","enabled":true"#)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.sources.filter(\.enabled).map(\.id) == ["eztv"])
    }

    @Test func loadSavesTheMigratedSettingsOnce() throws {
        let defaults = testDefaults()
        defaults.set(Self.savedWithChill(chillEnabled: true, othersEnabled: false), forKey: AppSettings.storageKey)
        let loaded = AppSettings.load(from: defaults)
        #expect(loaded.source("chill") == nil)
        #expect(loaded.sources.allSatisfy { $0.enabled })
        let stored = try #require(defaults.data(forKey: AppSettings.storageKey))
        #expect(!String(decoding: stored, as: UTF8.self).contains(#""chill""#), "saved again without chill")
        #expect(AppSettings.load(from: defaults) == loaded)
    }
}
