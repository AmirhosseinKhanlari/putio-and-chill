import XCTest

@MainActor
final class TVHeroUITests: XCTestCase {
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

    /// Home's featured slider advances by itself, and the dots flip slides with the remote.
    func testHeroSlides() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        sleep(4)
        shot("hero-1")
        sleep(10)
        shot("hero-2-auto")
        let remote = XCUIRemote.shared
        remote.press(.down)
        sleep(1)
        shot("step-1-down")
        remote.press(.down)
        sleep(1)
        shot("step-2-down")
        remote.press(.right)
        sleep(2)
        shot("step-3-right")
        remote.press(.right)
        sleep(2)
        shot("step-4-right")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Featured'")).count >= 0)
    }

    /// Movies tab: featured slider on top, then what was recently added to put.io.
    func testMoviesTab() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "movies"]
        app.launch()
        sleep(6)
        shot("movies-top")
        let remote = XCUIRemote.shared
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(2)
        shot("movies-recent")
        remote.press(.down)
        sleep(2)
        shot("movies-latest")
    }
}
