import XCTest

final class CompanionUITests: XCTestCase {
  @MainActor func launch(tab: String = "Folders") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["WOVENMATTER_UI_FIXTURE"] = "1"
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = tab
    app.launch()
    XCTAssertTrue(app.buttons["tab-folders"].waitForExistence(timeout: 10))
    return app
  }
  @MainActor func testFiveNativeTabsAndFocusedSurfaces() {
    let app = launch()
    XCTAssertTrue(app.staticTexts["Folders"].exists)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.buttons["action-new-note"].waitForExistence(timeout: 5))
    app.buttons["tab-content"].tap()
    XCTAssertTrue(app.textFields["Search notes and conversations"].exists)
    app.buttons["tab-chat"].tap()
    XCTAssertTrue(app.staticTexts["Summarize the launch plan."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
    app.buttons["tab-note"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["note-title"].firstMatch.waitForExistence(timeout: 5))
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Native note pane"; attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor func testOfflineWritingSurvivesTerminationAndRestart() {
    let app = launch()
    app.buttons["action-new-note"].tap()
    let title = app.descendants(matching: .any)["note-title"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.tap()
    let marker = " Restart proof " + String(UUID().uuidString.prefix(6))
    title.typeText(marker)
    let body = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' ")).firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    body.tap()
    let bodyText = "Offline body survives restart.\nSecond line retains the exact writing."
    body.typeText(bodyText)
    let writtenBody = body.value as? String
    XCTAssertEqual(writtenBody?.lowercased(), bodyText.lowercased())
    let saved = app.staticTexts["note-save-state"]
    let savedPredicate = NSPredicate(format: "label CONTAINS 'Saved on iPhone'")
    expectation(for: savedPredicate, evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = "Note"
    app.launch()
    let reopened = app.descendants(matching: .any)["note-title"].firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 10))
    XCTAssertTrue((reopened.value as? String ?? reopened.label).contains(marker.trimmingCharacters(in: .whitespaces)))
    XCTAssertTrue(app.staticTexts["note-save-state"].label.contains("Saved on iPhone"))
    let restoredBody = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' ")).firstMatch
    XCTAssertTrue(restoredBody.waitForExistence(timeout: 5))
    XCTAssertEqual(restoredBody.value as? String, writtenBody)
  }
  @MainActor func testFolderCanBeCreatedWithoutPairingOrNetwork() {
    let app = launch()
    app.buttons["New folder"].tap()
    let name = "Offline " + String(UUID().uuidString.prefix(6))
    app.alerts.textFields["Folder name"].typeText(name)
    app.alerts.buttons["Create"].tap()
    XCTAssertTrue(app.buttons.containing(.staticText, identifier: name).firstMatch.waitForExistence(timeout: 5))
  }
}
