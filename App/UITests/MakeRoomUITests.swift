import XCTest

@MainActor
final class MakeRoomUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// `-demoFull`: put.io has 1.5 GB free and Smart Get picks a 2.9 GB version. Get & Watch asks before deleting:
    /// the oldest movie is ticked, unticking everything disables Delete & Get, and confirming frees the room and sends.
    func testGetAndWatchOffersToMakeRoomAndAsksFirst() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoFull", "-demoScreen", "title"]
        app.launch()
        let get = app.buttons["Get & Watch"]
        XCTAssertTrue(get.waitForExistence(timeout: 20))
        get.tap()

        let message = app.staticTexts["makeRoom.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30), "the make-room question should appear")
        XCTAssertTrue(message.label.contains("you have 1.5 GB free"), message.label)
        let arrival = app.buttons["makeRoom.row.71"]
        let oppenheimer = app.buttons["makeRoom.row.73"]
        XCTAssertTrue(arrival.waitForExistence(timeout: 5))
        XCTAssertTrue(oppenheimer.exists)
        XCTAssertTrue(arrival.isSelected, "the oldest is suggested")
        XCTAssertFalse(oppenheimer.isSelected)
        let delete = app.buttons["makeRoom.delete"]
        XCTAssertTrue(delete.isEnabled)
        attach(app, "make-room-sheet")

        // Nothing ticked: nothing can be deleted.
        arrival.tap()
        XCTAssertFalse(delete.isEnabled)
        arrival.tap()
        XCTAssertTrue(delete.isEnabled)

        delete.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Freed 4 GB")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "the result should be shown")
        XCTAssertFalse(message.exists)
        attach(app, "make-room-done")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
