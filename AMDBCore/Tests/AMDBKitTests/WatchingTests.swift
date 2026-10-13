import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct SmartPickerTests {
    func rel(_ hash: Character, _ res: Resolution, gb: Double, seeders: Int) -> Release {
        var r = makeRelease(hash, seeders: seeders, name: "X.2024.\(res.label).WEB")
        r.sizeBytes = Int64(gb * 1_000_000_000)
        r.parsed.resolution = res
        return r
    }

    @Test func picksPreferredResolutionUnderSizeWithMostSeeders() {
        let releases = [rel("a", .fhd1080, gb: 12, seeders: 900), rel("b", .fhd1080, gb: 3, seeders: 400),
                        rel("c", .fhd1080, gb: 2, seeders: 600), rel("d", .uhd2160, gb: 8, seeders: 5000)]
        let rule = SmartGetRule(resolution: 1080, maxSizeGB: 10)
        #expect(SmartPicker.pick(releases, rule: rule)?.infoHash == String(repeating: "c", count: 40))
    }

    @Test func fallsBackToNextBestResolutionThenAnything() {
        let only720 = [rel("a", .hd720, gb: 1, seeders: 50), rel("b", .sd480, gb: 0.7, seeders: 80)]
        #expect(SmartPicker.pick(only720, rule: SmartGetRule(resolution: 1080, maxSizeGB: 10))?.parsed.resolution == .hd720)
        let only4K = [rel("a", .uhd2160, gb: 9, seeders: 50)]
        #expect(SmartPicker.pick(only4K, rule: SmartGetRule(resolution: 1080, maxSizeGB: 10))?.parsed.resolution == .uhd2160)
    }

    @Test func ignoresDeadAndOversizedReleases() {
        let releases = [rel("a", .fhd1080, gb: 3, seeders: 0), rel("b", .fhd1080, gb: 30, seeders: 999)]
        #expect(SmartPicker.pick(releases, rule: SmartGetRule(resolution: 1080, maxSizeGB: 10)) == nil)
    }

    @Test func bestQualityRulePrefers4K() {
        let releases = [rel("a", .fhd1080, gb: 3, seeders: 900), rel("b", .uhd2160, gb: 18, seeders: 100)]
        #expect(SmartPicker.pick(releases, rule: SmartGetRule(resolution: 2160, maxSizeGB: nil))?.parsed.resolution == .uhd2160)
    }
}

@Suite struct LanguageMatcherTests {
    @Test func matchesTwoAndThreeLetterCodes() {
        let available: [String?] = ["en", "fas", nil, "spa"]
        #expect(LanguageMatcher.bestIndex(available: available, preferred: "fa") == 1)
        #expect(LanguageMatcher.bestIndex(available: available, preferred: "es") == 3)
        #expect(LanguageMatcher.bestIndex(available: ["en-US", "fr"], preferred: "en") == 0)
        #expect(LanguageMatcher.bestIndex(available: ["per"], preferred: "fa") == 0)
        #expect(LanguageMatcher.bestIndex(available: available, preferred: "de") == nil)
    }
}

@Suite struct SettingsCompatibilityTests {
    @Test func olderSettingsKeepValuesAndGainNewDefaults() throws {
        let defaults = testDefaults()
        let old = #"{"sources":[{"id":"yts","name":"YTS","enabled":false,"baseURL":"https://x"}],"defaultResolution":720,"autoPlayCountdown":false}"#
        defaults.set(Data(old.utf8), forKey: "amdb.settings")
        let settings = AppSettings.load(from: defaults)
        #expect(settings.source("yts")?.enabled == false)
        #expect(settings.defaultResolution == 720)
        #expect(!settings.autoPlayCountdown)
        #expect(settings.autoPlayNextEpisode)
        #expect(settings.smartGet == SmartGetRule.recommended)
        #expect(settings.oneTapGet)
        #expect(settings.subtitleLanguage == nil)
    }
}

@MainActor @Suite struct SmartGetFlowTests {
    func app(snapshots: [ReleaseSnapshot], putio: FakePutio) -> AppModel {
        let factory = ServiceFactory(makePutio: { _ in putio }, makeCatalog: { _ in FakeCatalog() },
                                     makeProvider: { _, _ in nil })
        let model = AppModel(tokens: InMemoryTokenStore([.putio: "p", .tmdb: "t"]), defaults: testDefaults(),
                             store: LocalStore(fileURL: nil), factory: factory)
        model.overrideReleaseSearcher(FakeSearcher(snapshots: snapshots))
        return model
    }

    var target: TransferTarget {
        TransferTarget(tmdbID: 1, kind: .movie, title: "X", posterPath: nil, backdropPath: nil, season: nil, episode: nil)
    }

    @Test func sendsTheBestMatch() async {
        var done = ReleaseSnapshot()
        var good = makeRelease("c", seeders: 600, name: "X.2024.1080p.WEB")
        good.sizeBytes = 2_000_000_000
        done.releases = [makeRelease("a", seeders: 5, name: "X.2024.720p.WEB"), good]
        let putio = FakePutio()
        let model = app(snapshots: [done], putio: putio)
        let result = await model.smartGet(.movie(imdbID: "tt1", title: "X", year: 2024), target: target)
        model.transfers.stop()
        guard case let .sent(release) = result else { Issue.record("expected sent, got \(result)"); return }
        #expect(release.infoHash == String(repeating: "c", count: 40))
        #expect(putio.added.count == 1)
    }

    @Test func reportsNoMatchWithoutSending() async {
        var done = ReleaseSnapshot()
        done.releases = [makeRelease("a", seeders: 0, name: "X.2024.1080p.WEB")]
        let putio = FakePutio()
        let model = app(snapshots: [done], putio: putio)
        #expect(await model.smartGet(.movie(imdbID: "tt1", title: "X", year: 2024), target: target) == .noMatch)
        #expect(putio.added.isEmpty)
    }
}
