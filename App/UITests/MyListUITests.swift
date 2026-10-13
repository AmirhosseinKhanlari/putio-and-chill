import XCTest

@MainActor
final class MyListUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Save a title, then reach the full My List page from Home's "See all" and from the Library tab.
    func testSaveThenOpenFromHomeAndLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()
        let addButton = app.buttons["Add to My List"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 20))
        addButton.tap()
        XCTAssertTrue(app.buttons["Remove from My List"].waitForExistence(timeout: 5))
        app.buttons["Home"].tap()
        app.buttons["Home"].tap()

        let seeAll = app.buttons["See all My List"]
        for _ in 0..<4 where !(seeAll.exists && seeAll.isHittable) { app.swipeUp() }
        seeAll.tap()
        XCTAssertTrue(app.staticTexts["SAVED FOR LATER"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 movie"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "my-list"; shot.lifetime = .keepAlways; add(shot)

        app.buttons["Library"].tap()
        let fromLibrary = app.buttons["See all My List"]
        XCTAssertTrue(fromLibrary.waitForExistence(timeout: 5))
        fromLibrary.tap()
        XCTAssertTrue(app.staticTexts["SAVED FOR LATER"].waitForExistence(timeout: 5))
    }
}
