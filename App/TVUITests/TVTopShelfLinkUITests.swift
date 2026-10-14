import XCTest

@MainActor
final class TVTopShelfLinkUITests: XCTestCase {
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

    /// Selecting a Top Shelf item opens amdb://title/…; the app shows that title.
    func testTitleLinkOpensTheTitle() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        sleep(5)
        XCUIDevice.shared.system.open(URL(string: "amdb://title/movie/101")!)
        sleep(2)
        XCUIRemote.shared.press(.select)   // "Open" in the system prompt
        sleep(5)
        shot("topshelf-title-link")
        XCTAssertTrue(app.buttons["Get & Watch"].waitForExistence(timeout: 10) || app.buttons["Play"].exists)
    }
}
