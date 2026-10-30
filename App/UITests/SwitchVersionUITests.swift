import XCTest

@MainActor
final class SwitchVersionUITests: XCTestCase {
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

    /// A partly watched movie offers Versions next to Resume, on screen, so another copy can go on from there.
    func testPartlyWatchedMovieOffersVersions() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title-resume"]
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "Interstellar is partly watched in the demo")
        let versions = app.buttons["Versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5), "Versions is offered while resuming")
        XCTAssertTrue(versions.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(versions.frame), "Versions fits on screen: \(versions.frame)")
        shot("switch-version-1-title")
        versions.tap()
        XCTAssertTrue(app.staticTexts["Already in your put.io"].waitForExistence(timeout: 10))
        shot("switch-version-2-versions")
    }

    /// With larger text (as on a narrower iPhone) Resume, Download and Versions don't fit in a row: Versions shrinks
    /// to its icon and stays on screen.
    func testVersionsStaysOnScreenWithLargerText() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title-resume",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        let versions = app.buttons["Versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertTrue(versions.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(versions.frame), "Versions fits on screen: \(versions.frame)")
        shot("switch-version-3-large-text")
    }
}
