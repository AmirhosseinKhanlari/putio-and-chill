import XCTest

@MainActor
final class TVTitleShortcutUITests: XCTestCase {
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

    /// Hold Select on a Continue Watching card: "Go to Movie" / "Go to Show" opens the title page.
    func testHoldSelectOffersTheTitlePage() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 20))
        sleep(3)
        app.enterContent()
        let remote = XCUIRemote.shared
        // From the hero's buttons down to the first Continue Watching card (Severance in demo mode).
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        for _ in 0..<4 where !focused.label.contains("Severance") {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focused.label.contains("Severance"), "focus on the Continue Watching card, not \(focused.label)")
        shot("tv-hold-1-focus")
        remote.press(.select, forDuration: 1.6)
        sleep(1)
        shot("tv-hold-2-menu")
        let goTo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Go to'")).firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 5), "hold Select shows Go to Movie / Show")
        // Play is first; move to Go to and choose it.
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForNonExistence(timeout: 5), "title page replaced Home")
    }
}

extension XCUIApplication {
    /// When the app opens with focus in the sidebar (as Apple's TV app does), move it into the page.
    func enterContent() {
        let named = descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        for _ in 0..<2 where !named.exists {
            XCUIRemote.shared.press(.right)
            sleep(1)
        }
    }
}
