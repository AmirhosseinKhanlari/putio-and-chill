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
        attach("1-menu")
        let exact = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Interstellar.2014.1080p.BluRay.x264'")).firstMatch
        scroll(app, to: exact)
        XCTAssertTrue(exact.exists, "OpenSubtitles results sit in the same menu")
        for _ in 0..<5 where !putioEnglish.isHittable {
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
            sleep(1)
        }
        if !putioEnglish.exists { openMenu(app) }
        putioEnglish.tap()
        let putioLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'put.io line'")).firstMatch
        XCTAssertTrue(putioLine.waitForExistence(timeout: 10), "put.io subtitle draws over the video")

        openMenu(app)
        scroll(app, to: exact)
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

        // Style: solid box, yellow, large — saved and drawn on the video.
        let style = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Style'")).firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        style.tap()
        XCTAssertTrue(app.navigationBars["Subtitle Style"].waitForExistence(timeout: 5))
        for label in ["L", "Solid", "Yellow"] {
            let control = app.buttons[label]
            scroll(app, to: control)
            control.tap()
        }
        attach("4-style")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Large, solid box"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(openSubtitlesLine.waitForExistence(timeout: 10))
        attach("5-styled")
    }

    /// The subtitles button lives in the player's control bar; a tap brings the controls back when hidden.
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["Subtitles"]
        for attempt in 0..<3 {
            if waitHittable(button, seconds: 3) { break }
            if attempt < 2 { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        }
        if !button.isHittable {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "unreachable"; shot.lifetime = .keepAlways; add(shot)
            print("=== BUTTONS \(app.buttons.allElementsBoundByIndex.map { "\($0.label)=\($0.isHittable)" })")
        }
        XCTAssertTrue(button.isHittable, "subtitles button should be reachable")
        button.tap()
    }

    private func waitHittable(_ element: XCUIElement, seconds: Int) -> Bool {
        for _ in 0..<(seconds * 4) {
            if element.exists, element.isHittable { return true }
            usleep(250_000)
        }
        return false
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
