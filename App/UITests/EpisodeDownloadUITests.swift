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
        XCTAssertTrue(app.buttons["Download season"].waitForExistence(timeout: 10))
        let episodeDownload = app.buttons["Download to this device"].firstMatch
        for _ in 0..<3 where !(episodeDownload.exists && episodeDownload.isHittable) { app.swipeUp() }
        XCTAssertTrue(episodeDownload.exists)
        XCTAssertTrue(app.buttons["Play episode"].exists || app.buttons["Resume episode"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "season2"; shot.lifetime = .keepAlways; add(shot)
    }
}
