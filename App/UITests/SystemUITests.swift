import XCTest

@MainActor
final class SystemUITests: XCTestCase {
    /// Demo transfer → background the app → the Live Activity should be in the Dynamic Island.
    func testLiveActivityAppearsForTransfer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "title"]
        app.launch()
        let get = app.buttons["Get & Watch"]
        XCTAssertTrue(get.waitForExistence(timeout: 20))
        get.tap()
        sleep(3)
        attach(XCUIScreen.main.screenshot(), "1-in-app")
        XCUIDevice.shared.press(.home)
        sleep(2)
        attach(XCUIScreen.main.screenshot(), "2-home")
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(2)
        attach(XCUIScreen.main.screenshot(), "3-lock")
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
