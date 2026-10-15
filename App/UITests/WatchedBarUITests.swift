import XCTest

/// Started videos say how much is left and show a bar under their picture ("49:38" alone read like the length).
final class WatchedBarUITests: XCTestCase {
    func testEpisodeShowsTimeLeftAndWatchedBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "show"]
        app.launch()
        // Opens on the season being watched (Severance S2 E4, 20:50 into 55 minutes).
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season 2'")).firstMatch.waitForExistence(timeout: 20))
        let left = app.staticTexts["34m left"]
        for _ in 0..<6 where !(left.exists && left.isHittable) {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(left.exists, "the started episode says how much is left")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '38% watched'")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
