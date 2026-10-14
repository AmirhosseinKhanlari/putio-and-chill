import XCTest

@MainActor
final class AskAMDBUITests: XCTestCase {
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

    /// Needs Apple Intelligence on the machine running the simulator; skipped otherwise.
    func testAskTurnsASentenceIntoResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "search"]
        app.launch()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("a twisty 90s thriller under 2 hours")
        let ask = app.buttons["Ask Chill"]
        guard ask.waitForExistence(timeout: 5) else {
            shot("ask-unavailable")
            throw XCTSkip("Apple Intelligence isn't available in this simulator")
        }
        ask.tap()
        sleep(12)
        shot("ask-results")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'thriller' OR label CONTAINS '199'")).firstMatch.exists)
    }
}
