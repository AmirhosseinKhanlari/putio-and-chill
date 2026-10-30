import XCTest

/// Demo mode on Apple TV: Movies has New to Stream and Latest Movies; TV Shows has New Episodes This Week and Latest
/// Shows; Settings lists no chill account.
@MainActor
final class TVBrowseRowsUITests: XCTestCase {
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Moves down the page until every title has shown up (the shelves are built as they scroll in).
    private func scrollUntilSeen(_ app: XCUIApplication, _ titles: [String], presses: Int = 10) -> Set<String> {
        var seen: Set<String> = []
        for _ in 0...presses {
            for title in titles where app.staticTexts[title].exists { seen.insert(title) }
            if seen.count == titles.count { break }
            XCUIRemote.shared.press(.down)
            sleep(1)
        }
        return seen
    }

    func testMoviesTabRows() { check("movies", ["New to Stream", "Latest Movies"]) }

    func testTVShowsTabRows() { check("tvshows", ["New Episodes This Week", "Latest Shows"]) }

    private func check(_ screen: String, _ titles: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", screen]
        app.launch()
        sleep(6)
        XCUIRemote.shared.press(.right)
        sleep(1)
        let seen = scrollUntilSeen(app, titles)
        shot(screen)
        XCTAssertEqual(seen, Set(titles))
    }

    func testSettingsListNoChill() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        sleep(6)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Playback'")).firstMatch
            .waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'chill.'")).count, 0)
        shot("settings")
    }
}
