import XCTest

@MainActor
final class TVTopShelfUITests: XCTestCase {
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

    /// Opens the app (it writes the Top Shelf feed), goes Home and focuses AMDB to show its Top Shelf.
    func testTopShelfShowsContinueWatching() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        sleep(8)
        let remote = XCUIRemote.shared
        remote.press(.home)
        sleep(3)
        let home = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")
        let icon = home.otherElements["AMDB"].firstMatch
        shot("home-1")
        // Walk the top row until AMDB has focus.
        for _ in 0..<12 where !(icon.exists && icon.hasFocus) {
            remote.press(.right)
            usleep(600_000)
        }
        sleep(6)
        shot("home-topshelf")
    }
}
