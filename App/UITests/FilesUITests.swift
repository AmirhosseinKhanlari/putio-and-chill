import XCTest

@MainActor
final class FilesUITests: XCTestCase {
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

    /// Library → Files: open a folder, rename, move with Select, delete to Trash, then empty the Trash.
    func testBrowseRenameMoveDeleteAndEmptyTrash() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "library"]
        app.launch()

        let files = app.buttons["Files: browse and manage all of put.io"]
        XCTAssertTrue(files.waitForExistence(timeout: 20))
        files.tap()
        let downloads = app.buttons["Downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'in Trash'")).firstMatch.waitForExistence(timeout: 5),
                      "free space line shows the trash")
        shot("files-root")

        // Open a folder.
        downloads.tap()
        let notes = app.buttons["Release.Notes.txt"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))

        // Rename from the long-press menu.
        notes.press(forDuration: 1.2)
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("Readme.txt")
        // The alert slides up when the keyboard appears; tap once it has settled.
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        sleep(1)
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.buttons["Readme.txt"].waitForExistence(timeout: 5))

        // Select → Move into Archive.
        app.buttons["Select"].tap()
        app.buttons["Soundtrack.zip"].tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["Soundtrack.zip"].value as? String, "Selected", "the row shows it's selected")
        shot("files-selecting")
        app.buttons["Move"].tap()
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()
        let moveHere = app.buttons["Move Here"]
        XCTAssertTrue(moveHere.waitForExistence(timeout: 5))
        moveHere.tap()
        XCTAssertTrue(app.buttons["Soundtrack.zip"].waitForNonExistence(timeout: 5), "moved out of Downloads")

        // Delete the poster: it goes to the Trash.
        let poster = app.buttons["Severance.Poster.jpg"]
        poster.press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        app.buttons["Move to Trash"].tap()
        XCTAssertTrue(poster.waitForNonExistence(timeout: 5))

        // Back to the top, into the Trash.
        app.buttons["Back"].tap()
        let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trash'")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
        XCTAssertTrue(app.staticTexts["Severance.Poster.jpg"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Old.Movie.2001.720p.mkv"].exists)
        shot("files-trash")
        app.buttons["Empty Trash"].firstMatch.tap()
        // The confirmation's button is the newest one called Empty Trash.
        let confirm = app.buttons.matching(identifier: "Empty Trash")
        XCTAssertTrue(confirm.element(boundBy: 1).waitForExistence(timeout: 5))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(app.staticTexts["Empty"].waitForExistence(timeout: 5))
    }

    /// Swiping a video shows Move and Delete; each video row has a download button.
    func testSwipeActionsAndDownloadButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "files"]
        app.launch()
        let row = app.buttons["Past.Lives.2023.1080p.WEB.mkv"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Download to this device"].firstMatch.exists, "video rows have a download button")
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        shot("files-swipe-left")
        // Swiping right offers Download on a device; the Simulator can't download for offline use, so it isn't there.
    }

    /// The search field looks through every folder.
    func testSearchFindsFilesInFolders() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoScreen", "files"]
        app.launch()
        let field = app.textFields["Search all of put.io"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("soundtrack")
        XCTAssertTrue(app.buttons["Soundtrack.zip"].waitForExistence(timeout: 5))
        shot("files-search")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
