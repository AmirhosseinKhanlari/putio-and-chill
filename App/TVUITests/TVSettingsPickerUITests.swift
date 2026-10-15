import XCTest

@MainActor
final class TVSettingsPickerUITests: XCTestCase {
    private func shot(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func focus(_ app: XCUIApplication, _ prefix: String, max: Int = 8) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        for _ in 0..<max where !(focused.exists && focused.label.hasPrefix(prefix)) {
            XCUIRemote.shared.press(.down)
            sleep(1)
        }
    }

    /// Settings → Smart Get → Quality: the choices open, and Back returns, twice, to Settings.
    func testPickerOpensAndBackReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        sleep(6)
        let remote = XCUIRemote.shared
        // Into the page (the sidebar may have focus at launch), then down to Smart Get.
        remote.press(.right); sleep(1)
        remote.press(.right); sleep(1)
        focus(app, "Smart Get")
        remote.press(.select); sleep(2)
        shot("p1-smartget")
        focus(app, "Quality")
        remote.press(.select); sleep(2)
        shot("p2-quality")
        XCTAssertTrue(app.buttons["4K"].waitForExistence(timeout: 5), "the choices show")
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        for _ in 0..<4 where !(focused.exists && focused.label.hasPrefix("4K")) {
            remote.press(.up)
            sleep(1)
        }
        remote.press(.select); sleep(2)
        shot("p3-chosen")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Quality' AND label CONTAINS '4K'")).firstMatch
            .waitForExistence(timeout: 5) || app.staticTexts["4K"].exists, "back on Smart Get, Quality is 4K")
        remote.press(.menu); sleep(2)
        shot("p4-back")
        XCTAssertTrue(app.state == .runningForeground, "Back went up to Settings, not out of the app")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Playback'")).firstMatch.exists)
        XCTAssertTrue(app.state == .runningForeground)
    }
}
