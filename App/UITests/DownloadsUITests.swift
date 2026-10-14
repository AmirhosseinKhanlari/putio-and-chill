import XCTest

@MainActor
final class DownloadsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Library → Manage opens Downloads; a finished download plays, and long-press offers device vs stream.
    func testDownloadsPagePlaysAndOffersChoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()
        let manage = app.buttons["Manage downloads"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20))
        manage.tap()
        XCTAssertTrue(app.staticTexts["Downloads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Play downloads when available"].exists)
        let play = app.buttons["Play Severance from this device"]
        XCTAssertTrue(play.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "downloads"; shot.lifetime = .keepAlways; add(shot)

        play.tap()
        // This episode has a saved position, so the app asks first.
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume from'")).firstMatch
        if resume.waitForExistence(timeout: 5) { resume.tap() }
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 15), "player opens")
        app.buttons["Close"].tap()

        // The Library card's ⋯ menu offers device or stream.
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 10))
        app.buttons["Library"].tap()
        let more = app.buttons["More for Severance"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(app.buttons["Stream from put.io"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play from This Device"].exists)
        let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); menu.name = "menu"; menu.lifetime = .keepAlways; add(menu)
    }
}
