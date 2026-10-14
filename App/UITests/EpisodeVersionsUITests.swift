import XCTest

@MainActor
final class EpisodeVersionsUITests: XCTestCase {
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

    /// Every episode has a ⋯ menu with a way to pick another release, owned or not.
    func testEpisodeMenuOffersVersions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "show"]
        app.launch()
        let seasonMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season 1'")).firstMatch
        XCTAssertTrue(seasonMenu.waitForExistence(timeout: 20))
        seasonMenu.tap()
        app.buttons["Season 2"].tap()

        let more = app.buttons["More for episode 4"]
        for _ in 0..<4 where !(more.exists && more.isHittable) { app.swipeUp() }
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let another = app.buttons["Choose Another Version…"]
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stream from put.io"].exists)
        shot("episode-menu-owned")
        another.tap()
        sleep(3)
        shot("episode-versions-sheet")
        XCTAssertTrue(app.staticTexts["Choose a version"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Already in your put.io"].exists)
    }
}
