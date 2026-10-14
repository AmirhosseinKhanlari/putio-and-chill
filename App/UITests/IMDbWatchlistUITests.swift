import XCTest

@MainActor
final class IMDbWatchlistUITests: XCTestCase {
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

    /// Settings → Connected Services: a private watchlist explains itself; a public one connects and shows on Home.
    func testConnectIMDbWatchlist() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        let services = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connected Services'")).firstMatch
        for _ in 0..<4 where !(services.exists && services.isHittable) { app.swipeUp() }
        XCTAssertTrue(services.waitForExistence(timeout: 20))
        services.tap()
        let field = app.textFields["IMDb profile or watchlist link"]
        for _ in 0..<4 where !(field.exists && field.isHittable) { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        field.typeText("https://www.imdb.com/user/ur0000000/watchlist")
        app.buttons["Connect IMDb"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'public'")).firstMatch.waitForExistence(timeout: 10),
                      "a private watchlist says how to make it public")

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        field.typeText("https://www.imdb.com/user/ur12345678/watchlist")
        app.buttons["Connect IMDb"].tap()
        XCTAssertTrue(app.buttons["Disconnect IMDb"].waitForExistence(timeout: 10))
        shot("imdb-connected")
    }

    /// With a watchlist connected, Home has an IMDb Watchlist row; See all opens the grid.
    func testWatchlistOnHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoIMDb"]
        app.launch()
        let header = app.staticTexts["IMDb Watchlist"]
        for _ in 0..<6 where !(header.exists && header.isHittable) { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        shot("imdb-home")
        app.buttons["See all IMDb Watchlist"].tap()
        XCTAssertTrue(app.staticTexts["Watchlist"].waitForExistence(timeout: 5))
        shot("imdb-page")
    }
}
