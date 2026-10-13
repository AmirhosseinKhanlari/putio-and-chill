import XCTest

@MainActor
final class PlayerUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testPlayerHasOneCloseButtonAndItDismisses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()

        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20), "resume prompt should appear before playback")
        startOver.tap()

        sleep(4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let closeLabels = app.buttons.allElementsBoundByIndex
            .map { $0.label }
            .filter { ["close", "done", "dismiss"].contains(where: $0.lowercased().contains) }
        print("=== CLOSE BUTTONS === \(closeLabels)")
        XCTAssertFalse(closeLabels.contains("Close player"), "the app's own close button must be gone")
        XCTAssertEqual(closeLabels.count, 1, "exactly one close button expected, got \(closeLabels)")

        app.buttons[closeLabels[0]].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 10))
        sleep(2)
        let afterLabels = app.buttons.allElementsBoundByIndex.map { $0.label }
        XCTAssertFalse(afterLabels.contains("Play/Pause") || afterLabels.contains("Pause"), "player should be gone: \(afterLabels)")
    }
}
