import XCTest

/// The built-in player (AetherEngine) for videos Apple's player can't play. Needs real test videos served locally:
/// `MEDIA_BASE` (default http://127.0.0.1:8765) with xvid.avi (MPEG-4 Part 2 + MP3) and h264_dts.mkv (H.264 + DTS,
/// with an English SRT track inside). Skipped when the server isn't running.
@MainActor
final class BuiltInPlayerUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private var base: String { ProcessInfo.processInfo.environment["MEDIA_BASE"] ?? "http://127.0.0.1:8765" }

    /// XviD in AVI: Apple's player can't decode it, so the built-in player plays it with the app's own controls.
    func testUnsupportedVideoPlaysWithAppControls() throws {
        try requireServer("xvid.avi")
        let app = launch("xvid.avi")
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        sleep(10)
        showControls(app)
        for label in ["Skip back 10 seconds", "Skip forward 10 seconds", "Subtitles", "Playback speed", "AirPlay"] {
            XCTAssertTrue(app.buttons[label].exists || app.otherElements[label].exists, "missing control: \(label)")
        }
        XCTAssertFalse(failureShown(app), "no can't-play message")
        let before = position(app)
        XCTAssertGreaterThan(before, 0, "it plays")
        shot("builtin-xvid-controls")

        // Skip ahead twice and pause: the clock moves with it.
        app.buttons["Skip forward 10 seconds"].tap()
        app.buttons["Skip forward 10 seconds"].tap()
        sleep(2)
        showControls(app)
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let after = position(app)
        XCTAssertGreaterThanOrEqual(after, before + 15, "skipped ahead (\(before) → \(after))")
        shot("builtin-xvid-after-skip-paused")

        // Drag the timeline to about 80%.
        let timeline = app.descendants(matching: .any)["Playback position"]
        XCTAssertTrue(timeline.exists)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        sleep(3)
        showControls(app)
        let scrubbed = position(app)
        XCTAssertGreaterThanOrEqual(scrubbed, 42, "scrubbed to about 48 s (at \(scrubbed))")
        shot("builtin-xvid-scrubbed")
        // Playing again carries on from the scrubbed point.
        app.buttons["Play"].tap()
        sleep(3)
        showControls(app)
        XCTAssertGreaterThanOrEqual(position(app), scrubbed, "plays on from where it was scrubbed to")
        shot("builtin-xvid-scrubbed-playing")
        XCTAssertFalse(failureShown(app))
    }

    /// H.264 with DTS sound in MKV: built-in player; the subtitle track inside the file shows in the app's subtitle
    /// menu ("In the File") and draws in the app's subtitle style.
    func testEmbeddedSubtitlesFromTheFile() throws {
        try requireServer("h264_dts.mkv")
        let app = launch("h264_dts.mkv", codecs: "h264,dts")
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20))
        sleep(8)
        showControls(app)
        app.buttons["Subtitles"].tap()
        let header = app.staticTexts["In the File"]
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the file's own subtitle track is offered")
        shot("builtin-mkv-subtitle-menu")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Embedded subtitle line'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 25), "the embedded subtitle shows on the picture")
        shot("builtin-mkv-embedded-subtitle")
        XCTAssertFalse(failureShown(app))
    }

    // MARK: Helpers

    private func launch(_ file: String, codecs: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-url", "-demoPlayURL", "\(base)/\(file)"]
            + (codecs.map { ["-demoCodecs", $0] } ?? [])
        app.launch()
        return app
    }

    private func requireServer(_ file: String) throws {
        guard let url = URL(string: "\(base)/\(file)") else { throw XCTSkip("bad MEDIA_BASE") }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if !ok { throw XCTSkip("test video server not running at \(base)") }
    }

    private func showControls(_ app: XCUIApplication) {
        if !app.buttons["Close"].isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        _ = app.buttons["Close"].waitForExistence(timeout: 3)
    }

    /// Seconds from the "0:12 / −0:48" time label.
    private func position(_ app: XCUIApplication) -> Int {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' / '")).firstMatch
        // The controls may have just hidden themselves: bring them back.
        if !element.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        guard element.waitForExistence(timeout: 3) else { return -1 }
        let label = element.label
        let clock = label.components(separatedBy: " / ").first ?? ""
        return clock.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func failureShown(_ app: XCUIApplication) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS \"couldn't\" OR label CONTAINS \"isn't ready\"")).firstMatch.exists
    }

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
}
