import XCTest

/// Walks the remote across design-A screens and saves screenshots (focus states included) for review.
@MainActor
final class TVDesignShots: XCTestCase {
    private let remote = XCUIRemote.shared

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func launch(_ screen: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + (screen.map { ["-demoScreen", $0] } ?? [])
        app.launch()
        sleep(6)
        return app
    }

    func testFocusStates() {
        _ = launch(nil)
        remote.press(.down)
        sleep(2)
        shot("focus-home-hero")
        remote.press(.down)
        sleep(2)
        shot("focus-home-row")
        remote.press(.down)
        sleep(2)
        shot("focus-home-surprise")

        _ = launch("title")
        shot("focus-title")
        remote.press(.down)
        remote.press(.down)
        sleep(2)
        shot("focus-title-cast")

        _ = launch("show")
        remote.press(.down)
        remote.press(.down)
        sleep(2)
        shot("focus-show-episodes")

        _ = launch("library")
        remote.press(.down)
        sleep(2)
        shot("focus-library")
    }
}
