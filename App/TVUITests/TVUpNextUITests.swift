import XCTest

/// A show's episode watched past 95% (or into its credits), then Back: Continue Watching offers the next episode
/// (Up Next) in its place.
@MainActor
final class TVUpNextUITests: XCTestCase {
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
        // Severance S2 E4, a few seconds before its credits.
        app.launchArguments = ["-demo", "-demoScreen", "player-episode"]
        app.launch()
        sleep(7)
        shot("tv-upnext-1-playing")
        let remote = XCUIRemote.shared
        let shelf = app.descendants(matching: .any)["shelf.Continue Watching"]
        for _ in 0..<3 {
            remote.press(.menu)
            sleep(2)
            if shelf.exists, shelf.isHittable { break }
        }
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), "Continue Watching is on Home")
        remote.press(.down)
        remote.press(.down)
        sleep(2)
        shot("tv-upnext-2-home")
        let card = shelf.buttons.matching(NSPredicate(format: "label CONTAINS 'Up Next · S2 E5'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the next episode is up next")
        print("Up Next card: \(card.label)")
        XCTAssertEqual(shelf.buttons.firstMatch.label, card.label, "just watched: first")
        XCTAssertEqual(shelf.buttons.matching(NSPredicate(format: "label CONTAINS 'S2 E4'")).count, 0,
                       "the finished episode isn't in Continue Watching")
    }
}
