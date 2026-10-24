import XCTest

/// AirPlay can't run in the simulator: `-forceExternalPlayback` (DEBUG) takes the same path as a real TV. Picking a
/// subtitle then switches to a stream that carries it (the TV draws it, so the app doesn't), and the menu says the
/// TV's caption settings decide the look.
@MainActor
final class AirPlaySubtitleUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testSubtitlesGoInTheStreamDuringAirPlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player", "-forceExternalPlayback"]
        app.launch()
        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20))
        startOver.tap()

        // A put.io subtitle: put.io's stream with that track, drawn by the TV (not over the video here).
        openMenu(app)
        XCTAssertTrue(text(app, containing: "caption style").waitForExistence(timeout: 10), "the menu explains AirPlay")
        let putioEnglish = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).firstMatch
        XCTAssertTrue(putioEnglish.waitForExistence(timeout: 10))
        putioEnglish.tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
        sleep(6)
        XCTAssertFalse(text(app, containing: "put.io line").exists, "the TV draws it, the app doesn't")
        openMenu(app)
        XCTAssertTrue(text(app, containing: "Timing changes here don't reach the TV").waitForExistence(timeout: 15))
        attach("1-putio-on-tv")

        // An OpenSubtitles file: served from this device inside put.io's stream.
        let exact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interstellar.2014.1080p.BluRay.x264'")).firstMatch
        scroll(app, to: exact)
        XCTAssertTrue(exact.exists)
        exact.tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
        sleep(6)
        XCTAssertFalse(text(app, containing: "Demo subtitle line").exists, "the TV draws it, the app doesn't")
        openMenu(app)
        XCTAssertTrue(text(app, containing: "This device sends the subtitle to the TV").waitForExistence(timeout: 15))
        attach("2-device-on-tv")
        app.buttons["Done"].tap()

        // Manual checks of the served playlist (curl from the Mac): TEST_RUNNER_AIRPLAY_HOLD=<seconds>.
        if let hold = ProcessInfo.processInfo.environment["AIRPLAY_HOLD"].flatMap(UInt32.init) { sleep(hold) }
    }

    /// AirPlay ends: back to the plain stream, and the app draws the subtitle over the video again.
    func testTheAppDrawsAgainWhenAirPlayEnds() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player", "-forceExternalPlaybackSeconds", "30"]
        app.launch()
        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20))
        startOver.tap()
        openMenu(app)
        let exact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interstellar.2014.1080p.BluRay.x264'")).firstMatch
        scroll(app, to: exact)
        XCTAssertTrue(exact.waitForExistence(timeout: 10))
        exact.tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
        let line = text(app, containing: "Demo subtitle line")
        sleep(4)
        XCTAssertFalse(line.exists, "on AirPlay the TV draws it")
        XCTAssertTrue(line.waitForExistence(timeout: 60), "after AirPlay the app draws it again")
        openMenu(app)
        XCTAssertTrue(app.buttons["Show subtitles later"].waitForExistence(timeout: 10))
        XCTAssertFalse(text(app, containing: "caption style").exists, "no AirPlay note once it's over")
        attach("3-back-on-device")
    }

    private func text(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["Subtitles"]
        for attempt in 0..<3 {
            if button.waitForExistence(timeout: 3), button.isHittable { break }
            if attempt < 2 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        }
        XCTAssertTrue(button.isHittable, "subtitles button should be reachable")
        button.tap()
    }

    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<5 where !(element.exists && element.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
            sleep(1)
        }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
