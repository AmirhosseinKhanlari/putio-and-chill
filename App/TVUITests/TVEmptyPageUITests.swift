import XCTest

@MainActor
final class TVEmptyPageUITests: XCTestCase {
    /// An IMDb page with nothing connected still has something to select, and left reaches the sidebar from it.
    func testEmptyIMDbPageIsNotADeadEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "imdb"]
        app.launch()
        XCTAssertTrue(app.staticTexts["IMDb Watchlist"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Connect"].exists, "a Connect button")
        XCTAssertTrue(app.textFields.firstMatch.exists, "a field for the link")
        let remote = XCUIRemote.shared
        let myList = app.descendants(matching: .any)["My List"]
        for _ in 0..<3 where !myList.exists {
            remote.press(.left)
            sleep(1)
        }
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("imdb-empty.png"))
        }
        XCTAssertTrue(myList.exists, "left opens the sidebar")
    }
}
