import XCTest

/// Real data (no -demo): MDBList's chart rows and Lists on the Movies and TV tabs, with the built-in MDBList key.
@MainActor
final class MDBListUITests: XCTestCase {
    func testChartsAndListsOnMoviesAndTV() throws {
        let app = XCUIApplication()
        app.launch()
        guard ChartUITests.browseTab(app).waitForExistence(timeout: 25) else { throw XCTSkip("not signed in on this simulator") }

        for tab in ["Movies", "TV"] {
            ChartUITests.open(tab, app)
            let top10 = hittable(app.staticTexts["Top 10 on Streaming Today"], timeout: 30)
            XCTAssertNotNil(top10, "\(tab): Top 10 row should load")
            shot("\(tab.lowercased())-top")
        }

        ChartUITests.open("Movies", app)
        let seeAllLists = app.buttons["See all lists"]
        for _ in 0..<12 where !seeAllLists.isHittable { app.swipeUp() }
        shot("movies-lists-row")
        try XCTUnwrap(hittable(seeAllLists, timeout: 20), "Lists row should load").tap()
        XCTAssertTrue(app.staticTexts["Movie Lists"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Curated"].waitForExistence(timeout: 20), "curated lists should load")
        shot("movie-lists-page")

        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'titles'")).allElementsBoundByIndex.first { $0.isHittable }
        let name = try XCTUnwrap(card, "a list card").label.components(separatedBy: ",").first ?? ""
        card?.tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "list page should open: \(name)")
        sleep(4)
        shot("list-page")
        app.buttons["Back"].tap()

        let chart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Most Watched This Week'")).firstMatch
        try XCTUnwrap(hittable(chart, timeout: 10), "chart card").tap()
        XCTAssertTrue(app.staticTexts["MDBLIST CHART"].waitForExistence(timeout: 10))
        sleep(4)
        shot("chart-page")
    }

    private func hittable(_ element: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return element }
            sleep(1)
        }
        return nil
    }

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
}
