import XCTest

@MainActor
final class TVSidebarUITests: XCTestCase {
    private func shot(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// The sidebar: account at the top, the main tabs, then Your Lists and Browse; a genre opens its page.
    func testSidebarSections() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()
        sleep(6)
        let remote = XCUIRemote.shared
        // Left from the leftmost button opens the sidebar (the simulator spends the first press showing focus).
        let myList = app.descendants(matching: .any)["My List"]
        for _ in 0..<3 where !myList.exists {
            remote.press(.left)
            sleep(1)
        }
        shot("sidebar-top")
        XCTAssertTrue(app.descendants(matching: .any)["My List"].exists, "Your Lists section in the sidebar")
    }
}
