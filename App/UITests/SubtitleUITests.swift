import XCTest

@MainActor
final class SubtitleUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Player → subtitles button → OpenSubtitles results → pick → text on screen → shift timing.
    func testFindPickAndShiftSubtitles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20))
        startOver.tap()

        let find = app.buttons["Find subtitles"]
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        if !find.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        find.tap()

        let exact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interstellar.2014.1080p.BluRay.x264'")).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Matches this file"].exists)
        attach("1-results")
        exact.tap()

        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Demo subtitle line'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "picked subtitle should draw over the video")
        attach("2-playing")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !find.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        find.tap()
        let later = app.buttons["Show subtitles later"]
        XCTAssertTrue(later.waitForExistence(timeout: 10))
        later.tap()
        XCTAssertTrue(app.staticTexts["+0.5s"].waitForExistence(timeout: 5))
        attach("3-timing")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
