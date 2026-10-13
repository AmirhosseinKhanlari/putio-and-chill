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
}
