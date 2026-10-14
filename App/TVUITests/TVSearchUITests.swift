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

    /// Popular titles before typing; the on-screen keyboard types into the search and shows suggestions and results.
    func testSearchKeyboardAndResults() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "search"]
        app.launch()
        sleep(5)
        shot("search-empty")
        XCTAssertTrue(app.staticTexts["Popular Searches"].exists)

        let remote = XCUIRemote.shared
        remote.press(.down)
        sleep(1)
        shot("search-focus")
        remote.press(.select)   // types the focused key ("a")
        remote.press(.right)
        remote.press(.right)
        remote.press(.right)
        remote.press(.right)    // "e"
        remote.press(.select)
        sleep(3)
        shot("search-typed")
        XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 5))
    }
}
