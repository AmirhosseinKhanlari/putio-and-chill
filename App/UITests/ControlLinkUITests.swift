import XCTest

@MainActor
final class ControlLinkUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// The Surprise Me control opens amdb://surprise; the app shows Surprise Me.
    func testSurpriseLinkOpensSurpriseMe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        sleep(6)
        XCUIDevice.shared.system.open(URL(string: "amdb://surprise")!)
        // The system asks before opening an app from a link.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(app.buttons["Shuffle"].waitForExistence(timeout: 20))
    }
}
