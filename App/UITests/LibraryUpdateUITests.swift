import XCTest

@MainActor
final class LibraryUpdateUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// Library shows when it was last updated; Settings has automatic updates and "Update now".
    func testFreshnessAndUpdateSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()
        let freshness = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Updated'")).firstMatch
        XCTAssertTrue(freshness.waitForExistence(timeout: 20), "Library says when it was last updated")
        attach("library")

        app.buttons["Settings"].tap()
        let auto = app.switches["Update automatically"]
        for _ in 0..<8 where !(auto.exists && auto.isHittable) { app.swipeUp() }
        XCTAssertTrue(auto.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Check put.io every'")).firstMatch.exists)
        app.buttons["Update now"].tap()
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Up to date' OR value CONTAINS 'Up to date'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        attach("settings")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
