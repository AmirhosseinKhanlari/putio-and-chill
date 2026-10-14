import XCTest

@MainActor
final class GestureUITests: XCTestCase {
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

    /// Swiping right from the left edge of a title page goes back.
    func testSwipeBackFromATitle() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Furiosa'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        sleep(2)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        sleep(2)
        shot("after-swipe-back")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'TRENDING'")).firstMatch.waitForExistence(timeout: 5), "back on Home")
    }

    /// Dragging the player down closes it.
    func testSwipeDownClosesThePlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        let startOver = app.buttons["Start over"]
        if startOver.waitForExistence(timeout: 20) { startOver.tap() }
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "player is up")
        sleep(2)
        shot("player-before")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        sleep(3)
        shot("player-after-swipe")
        XCTAssertFalse(close.exists, "player closed")
    }
}
