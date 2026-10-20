import XCTest

/// The built-in player on Apple TV (videos Apple's player can't play), driven with the Siri Remote. Needs the test
/// videos served locally (see BuiltInPlayerUITests in the iPhone tests); skipped when the server isn't running.
@MainActor
final class TVBuiltInPlayerUITests: XCTestCase {
    private var base: String { ProcessInfo.processInfo.environment["MEDIA_BASE"] ?? "http://127.0.0.1:8765" }

    /// Click pauses (the bar shows), right skips, swipe down opens Subtitles / Audio / Speed with the file's own
    /// subtitle track, Menu backs out of the panel and then closes the player.
    func testRemoteDrivesTheBuiltInPlayer() throws {
        try requireServer("h264_dts.mkv")
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player-url", "-demoPlayURL", "\(base)/h264_dts.mkv", "-demoCodecs", "h264,dts"]
        app.launch()
        sleep(14)
        attach("tv-builtin-1-playing")
        let remote = XCUIRemote.shared
        remote.press(.playPause)
        sleep(2)
        attach("tv-builtin-2-paused-bar")
        remote.press(.right)
        remote.press(.right)
        sleep(2)
        attach("tv-builtin-3-skipped")
        remote.press(.down)
        sleep(2)
        attach("tv-builtin-4-menus")
        XCTAssertTrue(app.buttons["Subtitles"].exists || app.staticTexts["Subtitles"].exists, "the menus panel opens")
        // Down into the Subtitles list, to the file's own track ("In the File" comes after put.io's tracks).
        // "English · in the file" is put.io's copy of it; the built-in player's own track is just "English".
        let english = app.buttons.matching(NSPredicate(format: "label == 'English'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5), "the file's own subtitle track is offered")
        for _ in 0..<10 where !english.hasFocus {
            remote.press(.down)
            usleep(400_000)
        }
        XCTAssertTrue(english.hasFocus)
        remote.press(.select)
        sleep(1)
        remote.press(.menu)
        sleep(1)
        remote.press(.playPause)
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Embedded subtitle line'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 15), "the embedded subtitle shows")
        attach("tv-builtin-5-embedded-subtitle")
        remote.press(.menu)
        sleep(3)
        XCTAssertFalse(line.exists, "Menu closes the player")
        attach("tv-builtin-6-closed")
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

    private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
