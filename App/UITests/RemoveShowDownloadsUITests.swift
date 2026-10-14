import XCTest

@MainActor
final class RemoveShowDownloadsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// A series page with episodes on the device offers Remove Downloads for the whole show.
    func testRemoveAllDownloadsOfAShow() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "show"]
        app.launch()
        let remove = app.buttons["Remove all downloads of Severance from this device"]
        for _ in 0..<5 where !(remove.exists && remove.isHittable) { app.swipeUp() }
        XCTAssertTrue(remove.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 episode on this device'")).firstMatch.exists)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = "remove-show"; attachment.lifetime = .keepAlways; add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("remove-show.png"))
        }
        remove.tap()
        let confirm = app.buttons["Remove from This Device"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5), "nothing of the show is left on the device")
    }
}
