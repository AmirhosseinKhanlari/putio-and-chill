import XCTest

@MainActor
final class TVComingUpUITests: XCTestCase {
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

    func testMoviesAndTVShows() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "upcoming"]
        app.launch()
        sleep(6)
        shot("tv-comingup-movies")
        XCTAssertTrue(app.staticTexts["Box Office This Weekend"].exists)
        let remote = XCUIRemote.shared
        remote.press(.down)    // tab bar → Movies chip
        remote.press(.right)   // TV Shows chip
        remote.press(.select)
        sleep(4)
        shot("tv-comingup-tv")
        XCTAssertTrue(app.staticTexts["Your Upcoming Episodes"].exists)
    }
}
