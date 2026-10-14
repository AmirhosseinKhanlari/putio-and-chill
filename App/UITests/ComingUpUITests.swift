import XCTest

@MainActor
final class ComingUpUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

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

    func testMoviesAndTV() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "upcoming"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Box Office This Weekend"].waitForExistence(timeout: 20))
        sleep(2)
        shot("comingup-movies")
        app.segmentedControls.buttons["TV"].tap()
        XCTAssertTrue(app.staticTexts["Your Upcoming Episodes"].waitForExistence(timeout: 10))
        sleep(2)
        shot("comingup-tv")
        XCTAssertTrue(app.staticTexts["TODAY"].exists)
    }
}
