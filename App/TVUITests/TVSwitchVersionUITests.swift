import XCTest

@MainActor
final class TVSwitchVersionUITests: XCTestCase {
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

    /// A partly watched movie still offers Versions, after Resume and Start over, so another copy can go on from there.
    func testPartlyWatchedMovieOffersVersions() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title-resume"]
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "Interstellar is partly watched in the demo")
        let versions = app.buttons["Versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5), "Versions is offered while resuming")
        XCTAssertTrue(app.buttons["Start over"].exists)
        sleep(2)
        shot("tv-switch-version-1-title")

        // Out of the sidebar onto the page: Resume has focus first; right goes to Start over, then Versions.
        app.enterContent()
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        XCTAssertTrue(focused.label.hasPrefix("Resume"), "Resume has focus first, not \(focused.label)")
        let remote = XCUIRemote.shared
        for _ in 0..<3 where focused.label != "Versions" {
            remote.press(.right)
            sleep(1)
        }
        XCTAssertEqual(focused.label, "Versions")
        remote.press(.select)
        let owned = app.staticTexts["Already in put.io"]
        XCTAssertTrue(owned.waitForExistence(timeout: 10), "the versions page lists the copy already in put.io")
        sleep(2)
        shot("tv-switch-version-2-versions")
    }
}
