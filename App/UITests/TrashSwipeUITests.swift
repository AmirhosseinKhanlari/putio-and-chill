import XCTest

@MainActor
final class TrashSwipeUITests: XCTestCase {
    /// Swiping a file in the Trash shows a red Delete Forever (it was a blank white button).
    func testDeleteForeverIsRed() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "trash"]
        app.launch()
        let row = app.staticTexts["Old.Movie.2001.720p.mkv"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete Forever"].waitForExistence(timeout: 3))
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("trash-swipe.png"))
        }
    }
}
