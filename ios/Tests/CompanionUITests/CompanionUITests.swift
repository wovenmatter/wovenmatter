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
        // Rotation can temporarily detach the accessibility subtree. Avoid
        // frame lookups that retry internally while those rows are absent.
        guard sidebar.allSatisfy(\.exists) else {
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
  @MainActor func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingDown: Bool = true) {
    for _ in 0..<6 {
      if element.isHittable { return }
      if scrollingDown { app.swipeUp() } else { app.swipeDown() }
    }
    XCTAssertTrue(element.isHittable, "The requested folder navigation row must be reachable by scrolling")
  }

  @MainActor func testFolderHierarchyOrderTogglesAndMixedRecents() {
    let app = launch(scenario: "workspace-organization")
    let local = app.buttons["folders-local"], remote = app.buttons["folders-remote"]
    let localAgent = app.buttons["folder-agent-local:pi-durable-device"]
    let localFolder = app.buttons["folder-dddddddd-4444-4444-8444-444444444444"]
    XCTAssertTrue(localAgent.waitForExistence(timeout: 5))
    XCTAssertEqual(local.label, "Local Agent Workspace")
    XCTAssertEqual(remote.label, "Remote Workspaces")
    XCTAssertEqual(app.buttons["folder-all"].label, "All Workspaces")
    XCTAssertFalse(app.staticTexts["This iPhone"].exists)
    XCTAssertFalse(app.staticTexts["This iPad"].exists)
    XCTAssertFalse(app.buttons["All items"].exists)
    XCTAssertFalse(app.buttons["Unfiled items"].exists)
    XCTAssertFalse(app.buttons["folders-workspace"].exists)
    XCTAssertTrue(localFolder.exists)
    XCTAssertEqual(app.buttons["action-new-chat"].frame.minX, localAgent.frame.minX, accuracy: 1,
      "Workspace children must stay aligned with root rows")
    let localFolders = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace-folders-")).firstMatch
    XCTAssertTrue(localFolders.exists)
    localFolders.tap()
    XCTAssertFalse(localFolder.exists)
    XCTAssertTrue(localAgent.exists, "Collapsing Folders must leave its agent visible")
    localFolders.tap()
    XCTAssertTrue(localFolder.exists)
    local.tap()
    XCTAssertFalse(localAgent.exists)
    XCTAssertFalse(localFolder.exists)
    remote.tap()
    XCTAssertFalse(app.buttons["folder-workspace-cccccccc-3333-4333-8333-333333333333"].exists)
    let rows = [app.buttons["action-new-chat"], app.buttons["action-new-note"], app.buttons["folder-all"],
      local, remote, app.buttons["folders-trash"], app.buttons["folders-recents"]]
    for (above, below) in zip(rows, rows.dropFirst()) {
      XCTAssertTrue(above.exists); XCTAssertTrue(below.exists)
      XCTAssertLessThan(above.frame.minY, below.frame.minY)
    }
    let note = app.buttons["recent-note-organization-local-note"]
    let chat = app.buttons["recent-conversation-organization-ipad-chat"]
    XCTAssertTrue(note.exists); XCTAssertTrue(chat.exists)
    let recents = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "recent-note-", "recent-conversation-"))
    XCTAssertLessThanOrEqual(recents.count, 14)
    app.buttons["folders-recents"].tap()
    XCTAssertFalse(note.exists); XCTAssertFalse(chat.exists)
    app.buttons["folders-recents"].tap()
    XCTAssertTrue(note.exists); XCTAssertTrue(chat.exists)
    local.tap(); remote.tap()
    XCTAssertTrue(localAgent.exists)
    XCTAssertTrue(app.buttons["folder-workspace-cccccccc-3333-4333-8333-333333333333"].exists)
  }

  @MainActor func testWorkspaceOrganizationAndForeignQuickChatHistory() {
    let app = launch(scenario: "workspace-organization")
    XCTAssertTrue(app.buttons["folders-local"].exists)
    XCTAssertTrue(app.buttons["folders-remote"].exists)
    XCTAssertTrue(app.buttons["folder-dddddddd-4444-4444-8444-444444444444"].exists)
    XCTAssertTrue(app.buttons["folder-agent-local:pi-durable-device"].exists)
    let ipad = "cccccccc-3333-4333-8333-333333333333"
    reveal(app.buttons["folder-workspace-" + ipad], in: app)
    app.buttons["folder-workspace-" + ipad].tap()
    let folders = app.buttons["workspace-folders-" + ipad]
    XCTAssertTrue(folders.exists)
    XCTAssertTrue(app.buttons["folder-ffffffff-6666-4666-8666-666666666666"].exists)
    XCTAssertFalse(app.buttons["action-new-folder-" + ipad].exists)
    XCTAssertFalse(app.buttons["action-new-note-" + ipad].exists)
    reveal(folders, in: app)
    folders.tap()
    XCTAssertFalse(app.buttons["folder-ffffffff-6666-4666-8666-666666666666"].exists)
    folders.tap()
    XCTAssertTrue(app.buttons["folder-ffffffff-6666-4666-8666-666666666666"].exists)
    reveal(app.buttons["folder-all"], in: app, scrollingDown: false)
    app.buttons["folder-all"].tap()
    reveal(app.buttons["folder-chat-organization-ipad-chat"], in: app)
    app.buttons["folder-chat-organization-ipad-chat"].tap()
    XCTAssertTrue(app.staticTexts["Your weekend plan, saved from the iPad."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["chat-new-session"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["chat-composer"].exists)
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
    XCTAssertTrue(app.buttons["folders-local"].exists)
    XCTAssertTrue(app.buttons["folder-all"].exists)
    XCTAssertFalse(app.buttons["folders-workspace"].exists)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["pane-heading-woven matter"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["launch-agent-local:pi-durable-device"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["tab-content"].exists)
    app.buttons["tab-folders"].tap()
    app.buttons["folder-all"].tap()
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
    XCTAssertTrue(app.buttons["folder-all"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["folder-inbox"].exists, "Unassigned folders stay in All Workspaces")
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
    // The shared desktop transcript presents the active tail inline. Only
    // older work uses a collapsed group; the current tool owns its spinner.
    let activity = app.buttons["work-activity:fixture-current"]
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    let busyRows = app.buttons.matching(NSPredicate(format: "value ENDSWITH %@", ", In progress"))
    XCTAssertEqual(activity.value as? String, "Collapsed, In progress")
    XCTAssertEqual(busyRows.count, 1, "Only the current tool owns progress")
    XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Running on ")).firstMatch.exists)
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
    XCTAssertTrue(app.buttons["work-activity:fixture-current"].waitForExistence(timeout: 5))
    XCTAssertEqual(busyRows.count, 0, "Finished tools stop spinning while the agent continues its reply")
    XCTAssertEqual(app.buttons["work-activity:fixture-current"].value as? String, "Collapsed")
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Working for ")).firstMatch.exists)
  }

  @MainActor func testComposerShowsPermissionChoices() {
    let app = launch(tab: "Chats", scenario: "permissions")
    let permissions = app.buttons["chat-permissions"]
    XCTAssertTrue(permissions.waitForExistence(timeout: 5))
    XCTAssertTrue(permissions.isHittable)
    XCTAssertEqual(permissions.value as? String, "Allow Note Edits")
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
    XCTAssertTrue(app.buttons["Ask Before Note Edits"].exists)
    XCTAssertTrue(app.buttons["Allow Note Edits"].exists)
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

  @MainActor func testOfflineDeviceCreationExplainsConnectionAndSettingsHasNoPendingPage() {
    let app = launch(tab: "Home", scenario: "offline-device")
    let message = "Can’t connect to this device. Make sure it’s online and connected to the internet."
    app.buttons["action-new-chat"].tap()
    let agent = app.buttons["choose-chat-agent-11111111-2222-4333-8444-555555555555:pi"]
    XCTAssertTrue(agent.waitForExistence(timeout: 5))
    agent.tap()
    let chatError = app.staticTexts["chat-setup-problem"]
    XCTAssertTrue(chatError.waitForExistence(timeout: 5))
    XCTAssertEqual(chatError.label, message)
    app.buttons["Close agent chooser"].tap()
    app.buttons["tab-folders"].tap()
    reveal(app.buttons["folder-workspace-11111111-2222-4333-8444-555555555555"], in: app)
    app.buttons["folder-workspace-11111111-2222-4333-8444-555555555555"].tap()
    reveal(app.buttons["action-new-folder-11111111-2222-4333-8444-555555555555"], in: app)
    app.buttons["action-new-folder-11111111-2222-4333-8444-555555555555"].tap()
    XCTAssertFalse(app.alerts["New folder"].exists)
    let folderError = app.staticTexts["workspace-action-error"]
    XCTAssertTrue(folderError.waitForExistence(timeout: 5))
    XCTAssertEqual(folderError.label, message)
    app.buttons["tab-settings"].tap()
    XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Pending changes"].exists)
  }

  @MainActor func testNoteControlsAndCompactFooter() {
    let app = launch()
    app.buttons["tab-notes"].tap()
    let undo = app.buttons["note-undo"], redo = app.buttons["note-redo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5))
    XCTAssertTrue(redo.exists)
    XCTAssertFalse(undo.isEnabled); XCTAssertFalse(redo.isEnabled)
    XCTAssertFalse(app.buttons["Add paragraph"].exists)
    let count = app.buttons["note-text-count"]
    XCTAssertTrue(count.exists); XCTAssertEqual(count.label, "Note word count")
    count.tap(); XCTAssertEqual(count.label, "Note character count")
    count.tap(); XCTAssertEqual(count.label, "Note word count")
    let body = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' ")).firstMatch
    body.tap(); body.typeText(" undo marker")
    XCTAssertTrue(undo.isEnabled)
    undo.tap(); XCTAssertTrue(redo.isEnabled)
    redo.tap()
    XCTAssertTrue((body.value as? String ?? "").contains("marker"))
    app.buttons["note-format"].tap()
    XCTAssertTrue(app.buttons["Bold"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Add paragraph"].exists)
  }

  @MainActor func testOfflineWritingSurvivesTerminationAndRestart() {
    // CI stalled in XCTest's launch-rotation animation wait with Notes open.
    // Settle the Folders fixture before entering the editor.
    let app = launch()
    app.buttons["tab-notes"].tap()
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
    app.buttons["note-text-count"].tap()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 5))
    let saved = app.buttons["note-save-state"]
    let savedPredicate = NSPredicate(format: "label CONTAINS 'Saved on this device'")
    expectation(for: savedPredicate, evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = "Notes"
    app.launch()
    let reopened = app.descendants(matching: .any)["note-title"].firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 10))
    XCTAssertTrue((reopened.value as? String ?? reopened.label).contains(marker.trimmingCharacters(in: .whitespaces)))
    XCTAssertTrue(app.buttons["note-save-state"].label.contains("Saved on this device"))
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
      let heading = app.staticTexts["pane-heading-woven matter"]
      let destination = app.buttons["open-" + name]
      // Reselecting Home replaces its NavigationStack. Wait for the new root
      // and link to settle before sending the single navigation tap.
      var previousGeometry: [CGRect]?
      let homeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        guard heading.exists, destination.exists, heading.isHittable, destination.isHittable else {
          previousGeometry = nil
          return false
        }
        let geometry = [heading.frame, destination.frame]
        defer { previousGeometry = geometry }
        return previousGeometry == geometry
      }, object: app)
      XCTAssertEqual(XCTWaiter.wait(for: [homeReady], timeout: 5), .completed,
        "Home must settle before opening " + title)
      destination.tap()
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
