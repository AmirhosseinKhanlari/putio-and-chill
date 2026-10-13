import XCTest

@MainActor
final class TrailerUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testTrailerOpensInAppAndCloses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()

        let trailer = app.buttons["Trailer"]
        XCTAssertTrue(trailer.waitForExistence(timeout: 20), "title page should offer a trailer")
        trailer.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 20), "trailer sheet should open with a Done button")
        sleep(5)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        done.tap()
        XCTAssertTrue(trailer.waitForExistence(timeout: 10), "closing the trailer returns to the title page")
    }
}
