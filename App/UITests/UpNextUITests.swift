import XCTest

/// A show's episode watched past 95% (or into its credits) leaves Continue Watching; its next episode is up next instead.
@MainActor
final class UpNextUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

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

    func testWatchedEpisodeIsReplacedByTheNextOne() {
        let app = XCUIApplication()
        // Severance S2 E4, a few seconds before its credits: past 95% of the demo stream.
        app.launchArguments = ["-demo", "-demoScreen", "player-episode"]
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume from'")).firstMatch
        if resume.waitForExistence(timeout: 10) { resume.tap() }
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the player opens")
        sleep(4)
        shot("upnext-1-playing")
        if !close.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        close.tap()

        let row = app.descendants(matching: .any)["row.Continue Watching"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Continue Watching is on Home")
        let upNext = row.buttons.matching(NSPredicate(format: "label CONTAINS 'Up Next · S2 E5'")).firstMatch
        XCTAssertTrue(upNext.waitForExistence(timeout: 15), "the next episode is up next")
        print("Up Next card: \(upNext.label)")
        XCTAssertEqual(row.buttons.firstMatch.label, upNext.label, "just watched: first")
        let finished = row.buttons.matching(NSPredicate(format: "label CONTAINS 'S2 E4'"))
        XCTAssertEqual(finished.count, 0, "the finished episode isn't in Continue Watching")
        shot("upnext-2-home")
    }
}
