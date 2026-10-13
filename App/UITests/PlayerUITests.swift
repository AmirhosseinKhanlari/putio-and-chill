import XCTest

@MainActor
final class PlayerUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// The app's own player: one close button, transport and option controls, and closing returns home.
    func testPlayerControlsAndClose() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()

        let startOver = app.buttons["Start over"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 20), "resume prompt should appear before playback")
        startOver.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        sleep(5)
        if !close.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let closeLabels = app.buttons.allElementsBoundByIndex.map(\.label).filter { ["close", "done", "dismiss"].contains(where: $0.lowercased().contains) }
        XCTAssertEqual(closeLabels, ["Close"], "exactly one close button expected")
        for label in ["Skip back 10 seconds", "Skip forward 10 seconds", "Subtitles", "Playback speed", "AirPlay"] {
            XCTAssertTrue(app.buttons[label].exists || app.otherElements[label].exists, "missing control: \(label)")
        }
        XCTAssertTrue(app.buttons["Pause"].exists || app.buttons["Play"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "controls"
        shot.lifetime = .keepAlways
        add(shot)

        // Play/pause toggles and the controls stay up while paused.
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        sleep(5)
        XCTAssertTrue(app.buttons["Play"].isHittable, "controls stay visible while paused")

        close.tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertFalse(app.buttons["Play"].exists || app.buttons["Pause"].exists, "player should be gone")
    }
}
