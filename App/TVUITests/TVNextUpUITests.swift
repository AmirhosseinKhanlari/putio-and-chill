import XCTest

@MainActor
final class TVNextUpUITests: XCTestCase {
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

    /// The player's buttons aren't in the accessibility tree: records the screen when the credits start and after
    /// the countdown.
    func testNextEpisodeOffer() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-episode"]
        app.launch()
        sleep(16)
        shot("tv-nextup-offer")
        sleep(9)
        shot("tv-nextup-after-countdown")
    }
}
