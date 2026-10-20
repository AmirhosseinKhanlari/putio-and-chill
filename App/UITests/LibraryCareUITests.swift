import XCTest

@MainActor
final class LibraryCareUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testStorageMeterAndDeleteConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()
        let meter = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'put.io:'")).firstMatch
        XCTAssertTrue(meter.waitForExistence(timeout: 20), "storage meter should show put.io usage")
        print("=== \(meter.label)")

        let poster = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Past Lives'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(poster).press(forDuration: 1.2)
        let delete = app.buttons["Delete from put.io"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "long-press offers delete")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete from put.io?"].waitForExistence(timeout: 5), "delete asks for confirmation")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Long-press a Library card → Fix Match: search TMDB, pick the title, apply.
    func testFixMatchFromLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()
        let poster = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Past Lives'")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 20))
        let hittable = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Past Lives'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(hittable).press(forDuration: 1.2)
        let fix = app.buttons["Fix Match…"]
        XCTAssertTrue(fix.waitForExistence(timeout: 5), "long-press offers Fix Match")
        fix.tap()
        XCTAssertTrue(app.textFields["fixmatch.search"].waitForExistence(timeout: 10), "Fix Match opens with a search field")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Movie · 2023'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "the file's title is searched right away")
        result.tap()
        let apply = app.buttons["fixmatch.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "fix-match-chosen"
        shot.lifetime = .keepAlways
        add(shot)
        apply.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Matched to'")).firstMatch.waitForExistence(timeout: 5))
    }
}
