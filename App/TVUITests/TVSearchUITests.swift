import XCTest

@MainActor
final class TVSearchUITests: XCTestCase {
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

    /// Apple's search field and keyboard row, with its "Hold the microphone to dictate" hint (the system keyboard is
    /// what takes Siri Remote dictation) and popular titles under it; typing on it with the remote shows results.
    func testSystemSearchKeyboardAndResults() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "search"]
        app.launch()
        sleep(5)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the system search field is on screen")
        XCTAssertTrue(app.staticTexts["Popular Searches"].exists)

        let remote = XCUIRemote.shared
        // From the sidebar's Search into the page: the keyboard row takes focus.
        remote.press(.select)
        sleep(2)
        shot("search-focused")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the system keyboard is showing")
        XCTAssertTrue(field.hasFocus || app.keyboards.firstMatch.hasFocus, "typing goes to the search field")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to dictate'")).firstMatch.exists,
                      "the keyboard offers dictation")

        // Focus starts on "a": four to the right is "e".
        for _ in 0..<4 { remote.press(.right) }
        remote.press(.select)
        sleep(3)
        shot("search-typed")
        XCTAssertEqual(field.value as? String, "e")
        XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 5), "typing on the keyboard searches")
    }
}
