import XCTest

@MainActor
final class WatchingUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testSettingsShowPlaybackAndSmartGetOptions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20))
        for label in ["Auto-play next episode", "Audio language", "Subtitles", "One-tap Get", "Max size"] {
            var tries = 0
            while !app.staticTexts[label].exists && !app.switches[label].exists && tries < 8 {
                app.swipeUp()
                tries += 1
            }
            XCTAssertTrue(app.staticTexts[label].exists || app.switches[label].exists, "\(label) should be in Settings")
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
