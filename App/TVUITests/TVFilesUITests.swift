import XCTest

@MainActor
final class TVFilesUITests: XCTestCase {
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

    /// Library → Files lists the put.io root; selecting a folder opens it.
    func testBrowseFolders() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "files"]
        app.launch()
        XCTAssertTrue(app.buttons["Trash · 4.2 GB"].waitForExistence(timeout: 20))
        let remote = XCUIRemote.shared
        // Down to the Downloads folder, and open it.
        sleep(2)
        app.enterContent()
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND label != ''")).firstMatch
        for _ in 0..<5 where !(focused.exists && focused.label.hasPrefix("Downloads")) {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focused.label.hasPrefix("Downloads"), "focus on Downloads, not \(focused.label)")
        shot("tv-files-root")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Severance.Poster.jpg"].waitForExistence(timeout: 10))
        shot("tv-files-folder")
    }
}
