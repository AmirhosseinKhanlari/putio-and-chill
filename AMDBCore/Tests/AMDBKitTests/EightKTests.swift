import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

@Suite struct EightKTests {
    @Test func eightKReleasesAreRecognisedAndPicked() {
        #expect(ReleaseNameParser.parse("Planet.Earth.2006.4320p.UHD.HEVC").resolution == .uhd4320)
        #expect(ReleaseNameParser.parse("Planet Earth 2006 8K HDR").resolution == .uhd4320)
        #expect(ReleaseNameParser.parse("Dune.2021.2160p.WEB").resolution == .uhd2160)
        #expect(Resolution(label: "8K") == .uhd4320)
        let releases = [
            Release(name: "Planet.Earth.2160p", link: "magnet:a", sizeBytes: 1, seeders: 50, sources: []),
            Release(name: "Planet.Earth.4320p", link: "magnet:b", sizeBytes: 1, seeders: 5, sources: []),
        ]
        #expect(SmartPicker.pick(releases, rule: SmartGetRule(resolution: 4320, maxSizeGB: nil))?.link == "magnet:b")
        #expect(SmartPicker.pick(releases, rule: SmartGetRule(resolution: 2160, maxSizeGB: nil))?.link == "magnet:a")
    }
}
