import XCTest

@MainActor
final class TitleShortcutUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// Touch and hold a Recently Added card: its title page opens instead of the player.
    func testHoldingACardOpensTheTitlePage() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Past Lives'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5), "title page opens")
        XCTAssertFalse(app.buttons["Close"].exists, "the player didn't open")
        shot("hold-title")
    }

    /// The player's info button closes it and opens the movie's page.
    func testPlayerDetailsButtonOpensTheTitlePage() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20))
        startOver.tap()
        let details = app.buttons["Movie details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        if !details.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        shot("player-details-button")
        details.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "title page opens")
        XCTAssertFalse(app.buttons["Close"].exists, "the player closed")
        shot("player-details-title")
    }
}
