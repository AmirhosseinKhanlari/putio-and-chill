import XCTest

@MainActor
final class TVBackUITests: XCTestCase {
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

    /// Title page → Versions, then Back twice: one page at a time (never two at once), back to Home.
    func testBackGoesOnePageAtATime() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()
        let remote = XCUIRemote.shared
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        XCTAssertTrue(app.buttons["Versions"].waitForExistence(timeout: 20))
        // The simulator shows focus only after the first press of the remote.
        for _ in 0..<5 where !(focused.exists && focused.label == "Versions") {
            remote.press(.right)
            sleep(1)
        }
        XCTAssertEqual(focused.label, "Versions")
        remote.press(.select)
        let versionsPage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'best first' OR label CONTAINS 'Looking'")).firstMatch
        XCTAssertTrue(versionsPage.waitForExistence(timeout: 10), "versions open")
        // Focus up in the tab bar, like when the list is still loading.
        for _ in 0..<6 { remote.press(.up) }
        sleep(1)
        shot("tv-back-1-versions")
        remote.press(.menu)
        XCTAssertTrue(versionsPage.waitForNonExistence(timeout: 5), "Back left the versions page")
        XCTAssertTrue(app.buttons["Versions"].waitForExistence(timeout: 5), "one page back: the title page")
        shot("tv-back-2-title")
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 5), "and then Home")
    }
}
