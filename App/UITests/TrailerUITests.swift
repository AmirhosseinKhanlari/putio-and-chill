import XCTest

@MainActor
final class TrailerUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Furiosa (real IMDb id) should play its IMDb trailer in the app's player, then close back to the title page.
    func testTrailerPlaysNativelyAndCloses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()

        let trailer = app.buttons["Trailer"]
        XCTAssertTrue(trailer.waitForExistence(timeout: 20), "title page should offer a trailer")
        trailer.tap()

        sleep(8)
        let close = app.buttons["Close"]
        if !(close.exists && close.isHittable) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "player should be showing")
        XCTAssertTrue(app.buttons["Pause"].exists || app.buttons["Play"].exists, "player controls should be present")
        close.tap()
        XCTAssertTrue(trailer.waitForExistence(timeout: 10), "closing the trailer returns to the title page")
    }
}
