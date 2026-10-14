import XCTest

@MainActor
final class TapReliabilityUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// A finger never lands perfectly still: a tap that drifts a few points must still press the button.
    private func sloppyTap(_ element: XCUIElement, dx: CGFloat, dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
    }

    private func showControls(_ app: XCUIApplication) {
        if !app.buttons["Close"].isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
    }

    func testPauseAndPlay() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "player"]
        app.launch()
        let startOver = app.buttons["Start over"]
        if startOver.waitForExistence(timeout: 20) { startOver.tap() }
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 15))
        sleep(4)
        showControls(app)
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3), "exact tap pauses")
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3), "exact tap plays")
        showControls(app)
        sloppyTap(app.buttons["Pause"], dx: 2, dy: 14)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3), "a tap that drifts down still pauses")
    }

    func testBackButton() {
        for attempt in 0..<4 {
            let app = XCUIApplication()
            app.launchArguments = ["-demo", "-demoScreen", "title"]
            app.launch()
            let back = app.buttons["Back"]
            XCTAssertTrue(back.waitForExistence(timeout: 20))
            sleep(2)
            if attempt % 2 == 0 { back.tap() } else { sloppyTap(back, dx: attempt == 1 ? 14 : 6, dy: 4) }
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'TRENDING'")).firstMatch
                .waitForExistence(timeout: 5), "back works (attempt \(attempt))")
        }
    }

    /// The Settings gear opens Settings, also when the touch lands near (not exactly on) the icon.
    func testSettingsButton() {
        for (index, offset) in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.15, dy: 0.2), CGVector(dx: 0.85, dy: 0.8)].enumerated() {
            let app = XCUIApplication()
            app.launchArguments = ["-demo"]
            app.launch()
            let gear = app.buttons["Settings"]
            XCTAssertTrue(gear.waitForExistence(timeout: 20))
            sleep(1)
            gear.coordinate(withNormalizedOffset: offset).tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings opens (touch \(index))")
        }
    }
}
