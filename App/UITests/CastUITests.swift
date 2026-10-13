import XCTest

/// Uses the simulator's real sign-in (no -demo) to capture the title page with live TMDB data.
@MainActor
final class CastUITests: XCTestCase {
    func testCaptureRealTitlePage() throws {
        let app = XCUIApplication()
        app.launch()
        let moreInfo = app.buttons["More Info"].firstMatch
        guard moreInfo.waitForExistence(timeout: 25) else { throw XCTSkip("not signed in on this simulator") }
        moreInfo.tap()
        sleep(4)
        app.swipeUp()
        sleep(3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
