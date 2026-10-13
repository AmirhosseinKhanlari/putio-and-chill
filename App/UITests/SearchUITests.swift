import XCTest

/// Real data: "star wars" should keep loading more results as you scroll (TMDB pages beyond the first 20).
@MainActor
final class SearchUITests: XCTestCase {
    func testSearchLoadsMorePagesOnScroll() throws {
        let app = XCUIApplication()
        app.launch()
        guard app.buttons["Search"].waitForExistence(timeout: 25) else { throw XCTSkip("not signed in on this simulator") }
        app.buttons["Search"].tap()
        let field = app.textFields["Movies, shows, people"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("star wars")
        sleep(3)
        func posterCount() -> Int {
            app.buttons.allElementsBoundByIndex.filter { $0.label.localizedCaseInsensitiveContains("star wars") || $0.label.localizedCaseInsensitiveContains("mandalorian") }.count
        }
        let before = posterCount()
        for _ in 0..<6 { app.swipeUp(); sleep(1) }
        sleep(2)
        let after = posterCount()
        print("=== star wars results before=\(before) after=\(after)")
        XCTAssertGreaterThan(after, before, "scrolling should load more results")
    }
}
