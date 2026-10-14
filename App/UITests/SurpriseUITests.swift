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
        // Tonight's pick shows its title as text, or as its logo image when TMDB has one.
        let pick = app.descendants(matching: .any).matching(NSPredicate(
            format: "(label ==[c] %@ OR label ==[c] %@) AND elementType != %d", name, name.uppercased(), XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "picked alternative becomes tonight's pick")

        app.buttons["Watch This"].tap()
        // The title page: its logo (or title) and its own Back button.
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10))
        XCTAssertTrue(pick.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Shuffle"].exists, "surprise page closes and the title page opens")
    }
}
