import XCTest

final class CompanionUITests: XCTestCase {
  @MainActor func launch(tab: String = "Folders", scenario: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["WOVENMATTER_UI_FIXTURE_NAMESPACE"] = UUID().uuidString
    app.launchEnvironment["WOVENMATTER_UI_FIXTURE"] = "1"
    if let scenario { app.launchEnvironment["WOVENMATTER_UI_SCENARIO"] = scenario }
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = tab
    app.launch()
    XCTAssertTrue(app.buttons["tab-folders"].waitForExistence(timeout: 10))
    if app.buttons["tab-library"].exists {
      // Settle the iPad window transform before the first pointer event. On the
      // iOS 27 simulator, a fresh window can otherwise synthesize its first tap
      // at half the reported accessibility coordinates.
      XCUIDevice.shared.orientation = .landscapeLeft
      XCUIDevice.shared.orientation = .portrait
      // Orientation notifications can precede the accessibility transform. A
      // rotated sidebar row can still exist and report itself hittable while
      // its frame is vertical or outside the portrait window.
      let sidebar = [app.buttons["tab-home"], app.buttons["tab-folders"], app.buttons["tab-library"]]
      var previousGeometry: [CGRect]?
      let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        let window = app.windows.firstMatch
        guard window.exists, app.frame.height > app.frame.width else {
          previousGeometry = nil
          return false
        }
        let bounds = window.frame
        let rows = sidebar.map(\.frame)
        guard sidebar.allSatisfy(\.isHittable), rows.allSatisfy({
          $0.width > $0.height && $0.height > 0 && bounds.contains($0)
        }), zip(rows, rows.dropFirst()).allSatisfy({
          abs($0.0.minX - $0.1.minX) < 1 && $0.0.maxY <= $0.1.minY
        }) else {
          previousGeometry = nil
          return false
        }
        let geometry = [app.frame, bounds] + rows
        defer { previousGeometry = geometry }
        return previousGeometry == geometry
      }, object: app)
      XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed,
        "The iPad sidebar must settle into the portrait window before the first tap")
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
  @MainActor func testRunningToolsDoNotDuplicateProgressWhenExpanded() {
    let app = launch(tab: "Chats", scenario: "running-tools")
    let group = app.buttons["work-group:group:fixture-read"]
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    // SwiftUI combines a button's spinner into its accessibility element.
    // Assert the exposed progress owner across each disclosure state.
    let busyRows = app.buttons.matching(NSPredicate(format: "value ENDSWITH %@", ", In progress"))
    XCTAssertEqual(group.value as? String, "Collapsed, In progress")
    XCTAssertEqual(busyRows.count, 1, "Collapsed work has one progress owner")
    XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Running on ")).firstMatch.exists)
    group.tap()
    let activity = app.buttons["work-activity:fixture-current"]
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    XCTAssertEqual(group.value as? String, "Expanded")
    XCTAssertEqual(activity.value as? String, "Collapsed, In progress")
    XCTAssertEqual(busyRows.count, 1, "Expanded work moves progress to the current tool")
    activity.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Input")).firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(activity.value as? String, "Expanded, In progress")
    XCTAssertEqual(busyRows.count, 1, "Opening tool details does not add another progress owner")
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Running tool details without duplicate spinners"
    capture.lifetime = .keepAlways
    add(capture)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_SCENARIO"] = "running-tools-settled"
    app.launch()
    XCTAssertTrue(app.buttons["work-group:group:fixture-read"].waitForExistence(timeout: 5))
    XCTAssertEqual(busyRows.count, 0, "Finished tools stop spinning while the agent continues its reply")
    XCTAssertEqual(app.buttons["work-group:group:fixture-read"].value as? String, "Collapsed")
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Working for ")).firstMatch.exists)
  }

  @MainActor func testComposerShowsPermissionChoices() {
    let app = launch(tab: "Chats", scenario: "permissions")
    let permissions = app.buttons["chat-permissions"]
    XCTAssertTrue(permissions.waitForExistence(timeout: 5))
    XCTAssertTrue(permissions.isHittable)
    XCTAssertEqual(permissions.value as? String, "Full Access")
    let controls = [app.buttons["Add to chat"], app.buttons["chat-model"], app.buttons["chat-thinking"], permissions, app.buttons["chat-tools"], app.buttons["Send message"]]
    XCTAssertEqual(controls[1].value as? String, "GPT-6.1 Sol")
    XCTAssertEqual(controls[2].value as? String, "High")
    let dictation = app.buttons["dictation-microphone"]
    XCTAssertTrue(dictation.isHittable)
    XCTAssertLessThanOrEqual(dictation.frame.maxY, controls[0].frame.minY, "Dictation stays beside the editor above the settings row")
    for (left, right) in zip(controls, controls.dropFirst()) {
      XCTAssertEqual(left.frame.midY, right.frame.midY, accuracy: 1, "Composer controls stay on one row")
      XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX + 1, "Composer controls retain their order without overlap")
    }
    XCTAssertLessThanOrEqual(controls.last!.frame.maxX, app.frame.maxX)
    permissions.tap()
    XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Ask for Approval"].exists)
    XCTAssertTrue(app.buttons["Full Access"].exists)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Composer permissions"
    capture.lifetime = .keepAlways
    add(capture)
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
    let bodyEditors = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' "))
    guard bodyEditors.firstMatch.waitForExistence(timeout: 5) else {
      XCTFail("The fixture note editor must be visible before creating a new note")
      return
    }
    let originalEditorID = bodyEditors.firstMatch.identifier
    app.buttons["action-new-note"].tap()
    let title = app.descendants(matching: .any)["note-title"].firstMatch
    let body = bodyEditors.firstMatch
    let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      title.exists && title.value as? String == "Untitled note"
        && body.exists && body.identifier != originalEditorID && (body.value as? String ?? "").isEmpty
    }, object: app)
    guard XCTWaiter.wait(for: [created], timeout: 5) == .completed else {
      XCTFail("One New note tap must select a new, empty note before editing")
      return
    }
    title.tap()
    let marker = " Restart proof " + String(UUID().uuidString.prefix(6))
    title.typeText(marker)
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
