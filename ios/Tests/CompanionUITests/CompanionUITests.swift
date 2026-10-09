import XCTest

final class CompanionUITests: XCTestCase {
  @MainActor func launch(tab: String = "Folders") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["WOVENMATTER_UI_FIXTURE_NAMESPACE"] = UUID().uuidString
    app.launchEnvironment["WOVENMATTER_UI_FIXTURE"] = "1"
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = tab
    app.launch()
    XCTAssertTrue(app.buttons["tab-folders"].waitForExistence(timeout: 10))
    if app.buttons["tab-library"].exists {
      // Settle the iPad window transform before the first pointer event. On the
      // iOS 27 simulator, a fresh window can otherwise synthesize its first tap
      // at half the reported accessibility coordinates.
      XCUIDevice.shared.orientation = .landscapeLeft
      XCUIDevice.shared.orientation = .portrait
    }
    return app
  }
  @MainActor func testFiveNativeTabsAndFocusedSurfaces() {
    let app = launch()
    XCTAssertTrue(app.staticTexts["Folders"].exists)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
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
    let dismissKeyboard = app.buttons["dismiss-keyboard"]
    XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 5))
    dismissKeyboard.tap()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    let saved = app.staticTexts["note-save-state"]
    let savedPredicate = NSPredicate(format: "label CONTAINS 'Saved on this device'")
    expectation(for: savedPredicate, evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = "Note"
    app.launch()
    let reopened = app.descendants(matching: .any)["note-title"].firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 10))
    XCTAssertTrue((reopened.value as? String ?? reopened.label).contains(marker.trimmingCharacters(in: .whitespaces)))
    XCTAssertTrue(app.staticTexts["note-save-state"].label.contains("Saved on this device"))
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
  @MainActor func testWorkspaceSurfacesAndRotation() {
    let app = launch(tab: "Home")
    for name in ["library", "calendar", "trash"] {
      let sidebar = app.buttons["tab-" + name]
      if sidebar.exists { sidebar.tap() }
      else { app.buttons["tab-home"].tap(); app.buttons["open-" + name].tap() }
      let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Workspace " + name; attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertTrue(app.staticTexts["pane-heading-" + name].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connect to your Mac'")).firstMatch.waitForExistence(timeout: 5))
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    app.buttons["tab-note"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["note-title"].firstMatch.waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .portrait
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["action-new-note"].waitForExistence(timeout: 5))
  }

}
