import XCTest

@MainActor
final class EpisodeDownloadUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Episodes already in put.io offer "Download to this device"; the season offers "Download season".
    func testEpisodeAndSeasonDownloadButtons() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "show"]
        app.launch()
        let seasonMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season 1'")).firstMatch
        XCTAssertTrue(seasonMenu.waitForExistence(timeout: 20))
        seasonMenu.tap()
        app.buttons["Season 2"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Download season' OR label == 'Season downloaded' OR label ENDSWITH ' downloaded' OR label BEGINSWITH 'Download '")).firstMatch.waitForExistence(timeout: 10))
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play episode' OR label == 'Resume episode'")).firstMatch
        for _ in 0..<4 where !(play.exists && play.isHittable) { app.swipeUp() }
        XCTAssertTrue(play.exists)
        let rowButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download' AND label != 'Download season'")).firstMatch
        if !rowButton.exists {
            // iPhone: Download lives in the episode's ⋯ menu.
            app.buttons["More for episode 4"].tap()
            let item = app.buttons.matching(NSPredicate(format: "label == 'Download to This Device' OR label == 'Remove Download'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5))
        }
        // Only E4 of season 2 is downloaded in demo mode, so the season isn't "downloaded".
        XCTAssertFalse(app.buttons["Season downloaded"].exists)
        XCTAssertTrue(app.buttons["1 of 8 downloaded"].exists)
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = "season2"; shot.lifetime = .keepAlways; add(shot)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("season2.png"))
        }
    }
}
