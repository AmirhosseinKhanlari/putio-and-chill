import XCTest

@MainActor
final class NextUpUITests: XCTestCase {
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

    /// When the credits start, the Next Episode card appears; Watch Credits hides it.
    func testNextEpisodeCardAndWatchCredits() {
        let app = launch()
        let next = app.buttons["Next episode, S2 E5"]
        XCTAssertTrue(next.waitForExistence(timeout: 40), "card appears when the credits start")
        shot("nextup-card")
        app.buttons["Watch Credits"].tap()
        XCTAssertTrue(next.waitForNonExistence(timeout: 3), "Watch Credits hides it")
    }

    /// Left alone, the Next Episode button fills up and the next episode starts by itself.
    func testCountdownPlaysTheNextEpisode() {
        let app = launch()
        XCTAssertTrue(app.buttons["Next episode, S2 E5"].waitForExistence(timeout: 40))
        let nextEpisode = app.staticTexts["Season 2 · Episode 5"]
        XCTAssertTrue(nextEpisode.waitForExistence(timeout: 20), "S2 E5 starts after the countdown")
        shot("nextup-playing")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-episode"]
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume from'")).firstMatch
        if resume.waitForExistence(timeout: 20) { resume.tap() }
        return app
    }
}
