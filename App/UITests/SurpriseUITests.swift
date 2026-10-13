import XCTest

@MainActor
final class SurpriseUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Full-screen Surprise me: shuffle, swap in an alternative, open it.
    func testShuffleChooseAlternativeAndOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "surprise"]
        app.launch()
        let shuffle = app.buttons["Shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Not feeling it?"].exists)
        shuffle.tap()
        sleep(2)

        let alternative = app.buttons.matching(NSPredicate(format: "label == 'Arrival' OR label == 'Parasite' OR label == 'Past Lives' OR label == 'Oppenheimer'")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 5))
        let name = alternative.label
        alternative.tap()
        XCTAssertTrue(app.staticTexts[name.uppercased()].waitForExistence(timeout: 5), "picked alternative becomes tonight's pick")

        app.buttons["Watch This"].tap()
        XCTAssertTrue(app.staticTexts[name.uppercased()].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Shuffle"].exists, "surprise page closes and the title page opens")
    }
}
