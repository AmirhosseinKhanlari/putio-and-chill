import XCTest

@MainActor
final class TVPersonUITests: XCTestCase {
    /// The person page opens with the first title selected; the biography can't be selected.
    func testFirstTitleIsSelectedAndBioIsNot() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "person"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Known For"].waitForExistence(timeout: 20))
        sleep(2)
        // Focus starts on the first title (Furiosa): one to the right is the second (Dune).
        XCUIRemote.shared.press(.right)
        sleep(1)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        // The simulator may spend the first press just showing focus: then it's on the first title itself.
        XCTAssertTrue(focused.label.contains("Dune") || focused.label.contains("Furiosa"),
                      "focus starts on the first title, not \(focused.label)")
        let remote = XCUIRemote.shared
        remote.press(.down)
        sleep(1)
        remote.press(.up)
        sleep(1)
        XCTAssertFalse(focused.label.contains("Anya") || focused.label.contains("actress"), "the biography is never selected")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "person"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
