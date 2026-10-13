import XCTest

/// Real data (no -demo): checks the IMDb Top 250 rows load from Trakt on a signed-in simulator.
@MainActor
final class ChartUITests: XCTestCase {
    func testTop250RowsLoad() throws {
        let app = XCUIApplication()
        app.launch()
        let movies = app.buttons["Movies"]
        guard movies.waitForExistence(timeout: 25) else { throw XCTSkip("not signed in on this simulator") }

        for tab in ["Movies", "TV"] {
            app.buttons[tab].tap()
            // Hidden tabs stay alive (faded out), so only count elements the user can actually tap.
            func visible(_ prefix: String) -> XCUIElement? {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex
                    .first { $0.isHittable }
            }
            let deadline = Date().addingTimeInterval(30)
            while visible("Number 1,") == nil, Date() < deadline { sleep(1) }
            let first = try XCTUnwrap(visible("Number 1,"), "\(tab): Top 250 row should load")
            print("=== \(tab) #1: \(first.label) | \(visible("See all")?.label ?? "no See all")")
            XCTAssertEqual(first.label.contains("Breaking Bad"), tab == "TV")
            sleep(4)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = tab
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    func testSeeAllOpensFullPage() throws {
        let app = XCUIApplication()
        app.launch()
        guard app.buttons["Movies"].waitForExistence(timeout: 25) else { throw XCTSkip("not signed in on this simulator") }
        app.buttons["Movies"].tap()
        let seeAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'See all'")).allElementsBoundByIndex
        let deadline = Date().addingTimeInterval(30)
        var target = seeAll.first { $0.isHittable }
        while target == nil, Date() < deadline {
            sleep(1)
            target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'See all'")).allElementsBoundByIndex.first { $0.isHittable }
        }
        try XCTUnwrap(target, "See all should appear").tap()
        XCTAssertTrue(app.staticTexts["IMDB TOP 250"].waitForExistence(timeout: 10), "full chart page should open")
        sleep(5)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chart-page"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["IMDB TOP 250"].waitForNonExistence(timeout: 5), "back returns to Movies")
    }
}
