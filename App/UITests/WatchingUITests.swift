import XCTest

@MainActor
final class WatchingUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testSettingsShowPlaybackAndSmartGetOptions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20))
        // Settings is a list of pages: each holds its options.
        let pages: [(page: String, options: [String])] = [
            ("Playback", ["Auto-play next episode", "Audio language"]),
            ("Subtitles", ["Language"]),
            ("Smart Get", ["One-tap Get", "Max size"]),
        ]
        for (page, options) in pages {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page + ",")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(page) row")
            row.tap()
            for label in options {
                XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5) || app.switches[label].exists,
                              "\(label) should be in \(page)")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-playback"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Demo put.io "downloads" in ~8 s: one tap → best version sent → countdown → native player.
    func testOneTapGetDownloadsThenPlays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()
        let get = app.buttons["Get & Watch"]
        XCTAssertTrue(get.waitForExistence(timeout: 20))
        get.tap()
        let playNow = app.buttons["Play Now"]
        XCTAssertTrue(playNow.waitForExistence(timeout: 40), "countdown should appear once the transfer completes")
        playNow.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20), "native player should open")
    }
}
