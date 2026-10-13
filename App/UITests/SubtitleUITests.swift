import XCTest

@MainActor
final class SubtitleUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// One subtitles menu: put.io's tracks and OpenSubtitles results side by side; picks draw over the video.
    func testOneMenuForPutioAndOpenSubtitles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20))
        startOver.tap()

        openMenu(app)
        let putioEnglish = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).firstMatch
        XCTAssertTrue(putioEnglish.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["In the file"].exists)
        let exact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interstellar.2014.1080p.BluRay.x264'")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 10), "OpenSubtitles results sit in the same menu")
        attach("1-menu")
        putioEnglish.tap()
        let putioLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'put.io line'")).firstMatch
        XCTAssertTrue(putioLine.waitForExistence(timeout: 10), "put.io subtitle draws over the video")

        openMenu(app)
        for _ in 0..<3 where !(exact.exists && exact.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(exact.waitForExistence(timeout: 10))
        exact.tap()
        let openSubtitlesLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Demo subtitle line'")).firstMatch
        XCTAssertTrue(openSubtitlesLine.waitForExistence(timeout: 10))
        attach("2-playing")

        openMenu(app)
        let later = app.buttons["Show subtitles later"]
        XCTAssertTrue(later.waitForExistence(timeout: 10))
        later.tap()
        XCTAssertTrue(app.staticTexts["+0.5s"].waitForExistence(timeout: 5))
        attach("3-timing")
    }

    /// The button shows while paused; while playing it shows briefly after playback (re)starts.
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["Subtitles"]
        if !(button.waitForExistence(timeout: 3) && button.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let pause = app.buttons["Pause"]
            if pause.waitForExistence(timeout: 3) { pause.tap() }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
