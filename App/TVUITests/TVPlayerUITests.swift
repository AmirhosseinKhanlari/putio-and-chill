import XCTest

@MainActor
final class TVPlayerUITests: XCTestCase {
    /// Player transport bar: the player's own Subtitles (put.io tracks) and one OpenSubtitles button.
    /// (The player's controls aren't in the accessibility tree here, so this drives the remote and records screens.)
    func testPlayerMenus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        sleep(8)
        let remote = XCUIRemote.shared
        remote.press(.playPause)
        sleep(2)
        attach("1-transport")
        remote.press(.up)
        sleep(1)
        attach("2-focus-up")
        remote.press(.select)
        sleep(3)
        attach("3-menu")
        remote.press(.menu)
        sleep(1)
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        sleep(2)
        attach("4-next-menu")
    }

    private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
