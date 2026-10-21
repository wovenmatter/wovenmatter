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
  @MainActor func testDarkThemeSelectionPersistsAcrossLaunch() {
    let app = launch(tab: "Settings")
    app.buttons["General"].tap()
    let dark = app.buttons["Dark"]
    XCTAssertTrue(dark.waitForExistence(timeout: 5))
    dark.tap()
    XCTAssertTrue(dark.isSelected)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Dark theme settings"
    capture.lifetime = .keepAlways
    add(capture)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 10))
    app.buttons["General"].tap()
    XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Dark"].isSelected)
    // Keep the other UI tests on their original light appearance.
    app.buttons["Green"].tap()
  }

  @MainActor func testFiveNativeTabsAndFocusedSurfaces() {
    let app = launch()
    XCTAssertTrue(app.staticTexts["Folders"].exists)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["launch-agent-local:pi-durable-device"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["tab-content"].exists)
    app.buttons["tab-folders"].tap()
    app.buttons["folder-inbox"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-inbox"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["Search notes and conversations"].exists)
    XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Launch Plan").firstMatch.exists)
    app.buttons["tab-settings"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-settings"].waitForExistence(timeout: 5))
    app.buttons["General"].tap()
    XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Done"].exists)
    app.navigationBars["General"].buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["pane-heading-settings"].waitForExistence(timeout: 5))
    app.buttons["tab-folders"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-inbox"].waitForExistence(timeout: 5))
    app.buttons["back-folders"].tap()
    XCTAssertTrue(app.buttons["folder-inbox"].waitForExistence(timeout: 5))
    app.buttons["tab-chats"].tap()
    XCTAssertTrue(app.staticTexts["Summarize the launch plan."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
    app.buttons["tab-notes"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["note-title"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["dictation-microphone"].exists)
    let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Native note pane"; attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor func testPairingLivesInSettingsOutsideExecutionWorkspaces() {
    let app = launch(tab: "Settings")
    app.buttons["Workspaces"].tap()
    XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Pair with Mac"].exists)
    XCTAssertFalse(app.buttons["Mac pairing"].exists)
    XCTAssertFalse(app.buttons["Tailscale inference"].exists)
    app.navigationBars["Workspaces"].buttons.firstMatch.tap()
    app.buttons["Device Connections"].tap()
    XCTAssertTrue(app.navigationBars["Device Connections"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["pairing-scan"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["pairing-link"].exists)
    XCTAssertTrue(app.buttons["pairing-connect"].exists)
    XCTAssertFalse(app.buttons["Done"].exists)
    XCTAssertFalse(app.buttons["Sync status"].exists)
    XCTAssertFalse(app.buttons["Keep Offline"].exists)
  }

  @MainActor func testNewChatChooserAndKeyboardDismissal() {
    let app = launch(tab: "Home")
    app.buttons["action-new-chat"].tap()
    let chooser = app.buttons["choose-chat-agent-local:pi-durable-device"]
    XCTAssertTrue(chooser.waitForExistence(timeout: 5))
    app.buttons["Close agent chooser"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
    app.buttons["tab-folders"].tap()
    app.buttons["action-new-chat"].tap()
    XCTAssertTrue(chooser.waitForExistence(timeout: 5))
    chooser.tap()
    let composer = app.descendants(matching: .any)["chat-composer"].firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertEqual(composer.label, "Chat…")
    XCTAssertTrue(app.buttons["dictation-microphone"].exists)
    XCTAssertEqual(app.buttons["dictation-microphone"].label, "Start dictation")
    XCTAssertFalse(app.buttons["Conversation actions"].exists)
    XCTAssertFalse(app.buttons["Add connection"].exists)
    XCTAssertTrue(app.buttons["Choose model"].exists)
    XCTAssertTrue(app.buttons["Thinking level"].exists)
    XCTAssertTrue(app.buttons["Session tools"].exists)
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["dismiss-keyboard"].exists)
    app.staticTexts["New chat"].firstMatch.tap()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    app.buttons["chat-new-session"].tap()
    XCTAssertFalse(chooser.exists)
    XCTAssertTrue(composer.exists)
  }

  @MainActor func testOfflineWritingSurvivesTerminationAndRestart() {
    let app = launch(tab: "Notes")
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
    XCTAssertFalse(app.buttons["dismiss-keyboard"].exists)
    app.staticTexts["note-save-state"].tap()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    let saved = app.staticTexts["note-save-state"]
    let savedPredicate = NSPredicate(format: "label CONTAINS 'Saved on this device'")
    expectation(for: savedPredicate, evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = "Notes"
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
    let alert = app.alerts["New folder"]
    let field = alert.textFields["Folder name"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(name)
    // The remote iPad keyboard can finish delivering text after typeText
    // returns. Observe the complete value before reading or submitting it.
    let enteredName = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [enteredName], timeout: 5), .completed)
    XCTAssertEqual(field.value as? String, name)
    // One tap must submit while the keyboard is open, without a second tap to
    // compensate for the app's outside-tap keyboard dismissal gesture.
    alert.buttons["Create"].tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["back-folders"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["This folder is empty. Add a note or start a chat."].exists)
    app.buttons["back-folders"].tap()
    XCTAssertTrue(app.buttons.containing(.staticText, identifier: name).firstMatch.waitForExistence(timeout: 5))
  }
  @MainActor func testWorkspaceSurfacesAndRotation() {
    let app = launch(tab: "Home")
    for (name, title) in [("library", "Library"), ("calendar", "Calendar"), ("scheduled-tasks", "Scheduled tasks"), ("databases", "Databases"), ("usage", "Usage")] {
      app.buttons["tab-home"].tap()
      app.buttons["open-" + name].tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Done"].exists)
      XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connect to your Mac'")).firstMatch.exists)
      let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Workspace " + name; attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    app.buttons["tab-notes"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["note-title"].firstMatch.waitForExistence(timeout: 5))
    XCUIDevice.shared.orientation = .portrait
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["launch-agent-local:pi-durable-device"].waitForExistence(timeout: 5))
  }

}
