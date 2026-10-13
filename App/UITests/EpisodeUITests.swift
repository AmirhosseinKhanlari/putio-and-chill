import XCTest

@MainActor
final class EpisodeUITests: XCTestCase {
    /// Episode rows show each episode's IMDb score, flag the season's best one, and a download in flight
    /// shows only its ring (no text spilling out of the row).
    func testEpisodeRowsShowIMDbScoresAndCompactProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "show"]
        app.launch()
        let get = app.buttons["Get episode"].firstMatch
        XCTAssertTrue(get.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["IMDb 8.1"].waitForExistence(timeout: 10))
        get.tap()
        let ring = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Downloading, '")).firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Downloading"].exists)
        let best = app.descendants(matching: .any)["Best of season"]
        for _ in 0..<3 where !best.isHittable { app.swipeUp() }
        XCTAssertTrue(best.exists)
        XCTAssertTrue(app.descendants(matching: .any)["IMDb 9.3"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "episodes"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
