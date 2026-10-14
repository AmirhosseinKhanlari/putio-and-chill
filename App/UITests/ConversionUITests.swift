import XCTest

@MainActor
final class ConversionUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// A video Apple devices can't play as it is: the player shows put.io converting it, then plays it.
    func testPlayerWaitsForConversionThenPlays() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-convert"]
        app.launch()
        let card = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Converting for Apple devices'")).firstMatch
        let anyCard = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Converting for Apple devices'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20) || anyCard.exists, "conversion card shows")
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = "converting"; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("converting.png"))
        }
        XCTAssertTrue(anyCard.waitForNonExistence(timeout: 30), "it plays once put.io is done")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS \"couldn't\"")).firstMatch.exists)
    }
}
