import XCTest

/// Demo mode: the Movies / TV Shows rows that replaced the old Latest lists, and setup screens without any
/// release-search account.
@MainActor
final class BrowseRowsUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func noLabel(_ app: XCUIApplication, containing word: String) -> Bool {
        // The app's own name ("Putio & Chill", e.g. in the version line) doesn't count.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS 'Putio & Chill')", word)).count == 0
    }

    /// Movies: New to Stream and Latest Movies; TV Shows: New Episodes This Week and Latest Shows.
    func testNewAndLatestRowsOnMoviesAndTV() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "movies"]
        app.launch()
        XCTAssertTrue(text(app, "New to Stream").waitForExistence(timeout: 20))
        XCTAssertTrue(text(app, "Latest Movies").waitForExistence(timeout: 20))
        shot("movies")

        let tvSwitch = app.buttons["TV Shows"].firstMatch
        if tvSwitch.waitForExistence(timeout: 5), tvSwitch.isHittable {
            tvSwitch.tap()
        } else {
            app.tabBars.buttons["TV Shows"].firstMatch.tap()
        }
        XCTAssertTrue(text(app, "New Episodes This Week").waitForExistence(timeout: 20))
        XCTAssertTrue(text(app, "Latest Shows").waitForExistence(timeout: 20))
        shot("tv")
    }

    /// Settings: the sources are the six sites, and nothing asks for a chill account.
    func testSettingsHaveNoChillAccount() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "settings"]
        app.launch()
        let sources = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sources'")).firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 20))
        XCTAssertTrue(sources.label.contains("6 on"), sources.label)
        sources.tap()
        XCTAssertTrue(app.switches["YTS"].waitForExistence(timeout: 5))
        XCTAssertTrue(noLabel(app, containing: "chill"))
        shot("sources")
        app.navigationBars.buttons.firstMatch.tap()

        let services = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connected Services'")).firstMatch
        for _ in 0..<4 where !(services.exists && services.isHittable) { app.swipeUp() }
        XCTAssertTrue(services.waitForExistence(timeout: 5))
        services.tap()
        XCTAssertTrue(app.textFields["IMDb profile or watchlist link"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(noLabel(app, containing: "chill"))
        shot("services")
    }

    /// First-launch setup: put.io and the optional keys, no chill step.
    func testOnboardingHasNoChillStep() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoOnboarding"]
        app.launch()
        // The demo's put.io is connected, so its step shows as done (no sign-in button).
        XCTAssertTrue(app.staticTexts["Connect put.io"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Start watching"].exists)
        XCTAssertTrue(noLabel(app, containing: "Connect chill"))
        XCTAssertTrue(noLabel(app, containing: "indexers"))
        shot("onboarding")
    }
}
