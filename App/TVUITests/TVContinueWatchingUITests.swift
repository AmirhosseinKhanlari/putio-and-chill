import XCTest

@MainActor
final class TVContinueWatchingUITests: XCTestCase {
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

    /// Watching part of a download the library hasn't seen yet, then pressing Back: it's in Continue Watching on Home
    /// right away, with the time left.
    func testBackFromThePlayerShowsItInContinueWatching() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-new"]
        app.launch()
        sleep(8)
        let remote = XCUIRemote.shared
        // Past the 30 seconds that count as started: each click right skips ahead 10 seconds.
        for _ in 0..<4 {
            remote.press(.right)
            sleep(1)
        }
        sleep(3)
        shot("tv-continue-1-playing")

        // Back closes the player (a first press may only hide the controls).
        let shelf = app.descendants(matching: .any)["shelf.Continue Watching"]
        for _ in 0..<3 {
            remote.press(.menu)
            sleep(2)
            if shelf.exists, shelf.isHittable { break }
        }
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), "Continue Watching is on Home")
        // Down past the featured title onto the row, so its captions show.
        remote.press(.down)
        remote.press(.down)
        sleep(2)
        shot("tv-continue-2-home")
        let card = shelf.buttons.matching(NSPredicate(format: "label CONTAINS 'Arrival'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "the movie just watched is in Continue Watching")
        print("Continue Watching card: \(card.label)")
        XCTAssertTrue(card.label.contains("left"), "its card says how much is left: \(card.label)")
        // Most recently watched first.
        XCTAssertEqual(shelf.buttons.firstMatch.label, card.label)
    }
}
