import XCTest
import UIKit

final class MobileUITests: XCTestCase {
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

  @MainActor func testRemoteWorkspaceWithoutFoldersExplainsWhereToCreateThem() {
    let app = launch(scenario: "remote-folders-empty")
    let linux = "bbbbbbbb-2222-4222-8222-222222222222"
    let caption = app.staticTexts["workspace-folders-empty-" + linux]
    XCTAssertTrue(caption.waitForExistence(timeout: 5))
    XCTAssertEqual(caption.label, "No folders yet. Create folders on Linux workspace.")
    XCTAssertFalse(app.buttons["action-new-folder-" + linux].exists, "Remote folders are created on their own machine")
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
    // Agent replies render in a selectable text view, not a static label.
    let reply = app.textViews.matching(NSPredicate(format: "label == 'Agent response' AND value CONTAINS %@", "Your weekend plan, saved from the iPad.")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 5), "The foreign Quick Chat transcript shows its saved reply")
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
    // Live tools stay individually visible until another event folds them
    // into history. Expanding a tool must retain exactly one progress owner.
    let activity = app.buttons["work-activity:fixture-current"]
    let finishedActivity = app.buttons["work-activity:fixture-read"]
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    XCTAssertTrue(finishedActivity.exists)
    XCTAssertFalse(app.buttons["work-group:group:fixture-read"].exists)
    let busyRows = app.buttons.matching(NSPredicate(format: "value ENDSWITH %@", ", In progress"))
    XCTAssertEqual(activity.value as? String, "Collapsed, In progress")
    XCTAssertEqual(finishedActivity.value as? String, "Collapsed")
    XCTAssertEqual(busyRows.count, 1, "Only the current live tool owns progress")
    XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Running on ")).firstMatch.exists)
    activity.tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Input")).firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(activity.value as? String, "Expanded, In progress")
    XCTAssertEqual(busyRows.count, 1, "Opening tool details does not add another progress owner")
    activity.tap()
    XCTAssertEqual(activity.value as? String, "Collapsed, In progress")
    XCTAssertEqual(busyRows.count, 1, "Closing tool details keeps the same progress owner")
    activity.tap()
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Running tool details without duplicate spinners"
    capture.lifetime = .keepAlways
    add(capture)
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_SCENARIO"] = "running-tools-settled"
    app.launch()
    XCTAssertTrue(activity.waitForExistence(timeout: 5))
    XCTAssertEqual(busyRows.count, 0, "Finished tools stop spinning while the agent continues its reply")
    XCTAssertEqual(activity.value as? String, "Collapsed")
    XCTAssertEqual(finishedActivity.value as? String, "Collapsed")
    XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Working for ")).firstMatch.exists)
  }

  @MainActor func testComposerShowsPermissionChoices() {
    let app = launch(tab: "Chats", scenario: "permissions")
    let permissions = app.buttons["chat-permissions"]
    XCTAssertTrue(permissions.waitForExistence(timeout: 5))
    XCTAssertTrue(permissions.isHittable)
    XCTAssertEqual(permissions.value as? String, "Full Access", "Quick Chat starts with Full Access")
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

  /// An unreachable workspace is not offered anywhere a chat starts; it waits
  /// in Settings → Workspaces until it reconnects.
  @MainActor func testOfflineDeviceIsNotOfferedAndSettingsHasNoPendingPage() {
    let app = launch(tab: "Home", scenario: "offline-device")
    let offline = "11111111-2222-4333-8444-555555555555"
    XCTAssertTrue(app.buttons["launch-agent-local:pi-durable-device"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["launch-agent-" + offline + ":pi"].exists)
    XCTAssertFalse(app.staticTexts["Offline Linux"].exists)
    app.buttons["action-new-chat"].tap()
    XCTAssertTrue(app.buttons["choose-chat-agent-local:pi-durable-device"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["choose-chat-agent-" + offline + ":pi"].exists)
    app.buttons["Close agent chooser"].tap()
    app.buttons["tab-folders"].tap()
    XCTAssertTrue(app.buttons["folders-remote"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["folder-workspace-" + offline].exists)
    XCTAssertTrue(app.staticTexts["folders-remote-empty"].exists)
    app.buttons["tab-settings"].tap()
    XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Pending changes"].exists)
  }

  /// Home lists Quick Chat before Workspaces, and Home and Folders list only
  /// reachable workspaces: no saved-but-unreachable Mac or Linux workspace and
  /// no "Unavailable workspace" for folders whose owner is not listed.
  @MainActor func testHomeLeadsWithQuickChatAndListsOnlyReachableWorkspaces() {
    let app = launch(tab: "Home", scenario: "unreachable-workspaces")
    let build = "cccccccc-9999-4999-8999-999999999999"
    let quickChat = app.staticTexts["home-quick-chat"], workspaces = app.staticTexts["home-workspaces"]
    XCTAssertTrue(quickChat.waitForExistence(timeout: 5))
    XCTAssertTrue(workspaces.exists)
    XCTAssertLessThan(quickChat.frame.minY, workspaces.frame.minY, "Quick Chat leads the home page")
    XCTAssertLessThan(app.buttons["launch-agent-local:pi-durable-device"].frame.minY, workspaces.frame.minY)
    XCTAssertTrue(app.staticTexts["Build server"].exists)
    XCTAssertTrue(app.buttons["launch-agent-" + build + ":default_agent"].isEnabled)
    XCTAssertFalse(app.buttons["launch-agent-" + build + ":codex"].isEnabled, "An agent its workspace reports not ready stays dimmed")
    XCTAssertFalse(app.staticTexts["Office Mac"].exists)
    XCTAssertFalse(app.staticTexts["Old Linux box"].exists)
    XCTAssertFalse(app.staticTexts["Copied MacBook Air"].exists, "A copied snapshot owner is history, not a workspace")
    app.buttons["tab-folders"].tap()
    XCTAssertTrue(app.buttons["folder-workspace-" + build].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["folder-workspace-aaaaaaaa-7777-4777-8777-777777777777"].exists)
    XCTAssertFalse(app.buttons["folder-workspace-bbbbbbbb-8888-4888-8888-888888888888"].exists)
    XCTAssertFalse(app.buttons["folder-workspace-dddddddd-0000-4000-8000-000000000000"].exists)
    XCTAssertFalse(app.buttons["Unavailable workspace"].exists)
    XCTAssertFalse(app.staticTexts["Unavailable workspace"].exists)
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
    // Return starts a second paragraph block; typing continues there.
    let paragraphs = ["Offline body survives restart.", "Second line retains the exact writing."]
    body.typeText(paragraphs[0] + "\n")
    let second = bodyEditors.element(boundBy: 1)
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    XCTAssertTrue(waitForKeyboardFocus(second))
    app.typeText(paragraphs[1])
    let writtenBody = (0..<2).map { bodyEditors.element(boundBy: $0).value as? String ?? "" }
    XCTAssertEqual(writtenBody.map { $0.lowercased() }, paragraphs.map { $0.lowercased() })
    XCTAssertFalse(app.buttons["dismiss-keyboard"].exists)
    app.buttons["note-text-count"].tap()
    // A tap outside the editor and its editing controls still ends editing.
    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == false"), object: second)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "An ordinary outside tap dismisses the keyboard")
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
    let restoredBody = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' "))
    XCTAssertTrue(restoredBody.element(boundBy: 1).waitForExistence(timeout: 5))
    XCTAssertEqual(restoredBody.count, 2)
    XCTAssertEqual((0..<2).map { restoredBody.element(boundBy: $0).value as? String ?? "" }, writtenBody)
  }
  @MainActor func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
    let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
    return XCTWaiter.wait(for: [focused], timeout: 5) == .completed
  }
  @MainActor func testReturnStartsParagraphsAndDeleteJoinsThemWithUndo() {
    let app = launch()
    app.buttons["tab-notes"].tap()
    let editors = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' "))
    XCTAssertTrue(editors.firstMatch.waitForExistence(timeout: 5))
    let originalEditorID = editors.firstMatch.identifier
    app.buttons["action-new-note"].tap()
    let first = editors.firstMatch
    let created = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      first.exists && first.identifier != originalEditorID && (first.value as? String ?? "").isEmpty
    }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 5), .completed)
    app.buttons["note-format"].tap()
    app.buttons["Heading and style"].tap()
    app.buttons["Heading 1"].tap()
    first.tap()
    first.typeText("Plan")
    first.typeText("\n")
    let second = editors.element(boundBy: 1)
    XCTAssertTrue(second.waitForExistence(timeout: 5), "Return creates a paragraph instead of a line inside the heading")
    XCTAssertTrue(waitForKeyboardFocus(second), "Typing continues in the new paragraph")
    app.typeText("Details")
    XCTAssertEqual(first.value as? String, "Plan")
    XCTAssertEqual(second.value as? String, "Details")
    let undo = app.buttons["note-undo"], redo = app.buttons["note-redo"]
    undo.tap()
    XCTAssertEqual(second.value as? String, "")
    undo.tap()
    XCTAssertEqual(editors.count, 1, "Undo removes the paragraph break as one step")
    XCTAssertEqual(first.value as? String, "Plan")
    XCTAssertTrue(waitForKeyboardFocus(first), "Undo keeps editing in the restored paragraph")
    redo.tap()
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    // No tap: redo returns the caret to the recreated paragraph.
    XCTAssertTrue(waitForKeyboardFocus(second), "Redo continues editing in the new paragraph")
    app.typeText(XCUIKeyboardKey.delete.rawValue)
    let joined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editors.count == 1 }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 5), .completed, "Delete at a paragraph start joins it to the previous one")
    XCTAssertEqual(first.value as? String, "Plan")
    // Undo the join, then the break: the focused paragraph disappears again.
    undo.tap()
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    undo.tap()
    let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editors.count == 1 }, object: app)
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
    XCTAssertTrue(waitForKeyboardFocus(first))
    app.typeText("!")
    XCTAssertEqual(first.value as? String, "Plan!", "Typing right after undo lands at the restored caret")
    app.buttons["note-format"].tap()
    app.buttons["Bold"].tap()
    XCTAssertFalse(app.staticTexts["workspace-action-error"].waitForExistence(timeout: 2), "Formatting addresses the restored paragraph")
    XCTAssertEqual(first.value as? String, "Plan!")
  }
  /// A note holding only a table offers one empty paragraph after it. Writing
  /// there adds prose that survives a relaunch beside the read-only table; the
  /// table's exact data is checked by RichDocumentParagraphTests.
  @MainActor func testWritingContinuesAfterATableOnlyNote() {
    let app = launch(tab: "Notes", scenario: "table-note")
    let editors = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' "))
    let table = app.descendants(matching: .any)["Table, read only"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    XCTAssertTrue(editors.firstMatch.waitForExistence(timeout: 5), "An empty paragraph follows the table")
    XCTAssertEqual(editors.count, 1)
    XCTAssertFalse(app.buttons["Add paragraph"].exists)
    let after = editors.firstMatch
    XCTAssertGreaterThan(after.frame.minY, table.frame.minY)
    after.tap()
    after.typeText("After the table")
    XCTAssertEqual(after.value as? String, "After the table")
    let saved = app.buttons["note-save-state"]
    expectation(for: NSPredicate(format: "label CONTAINS 'Saved on this device'"), evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    app.terminate()
    app.launch()
    let reopened = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' "))
    XCTAssertTrue(app.descendants(matching: .any)["Table, read only"].waitForExistence(timeout: 10))
    XCTAssertTrue(reopened.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(reopened.count, 1, "The written paragraph replaces the offered one")
    XCTAssertEqual(reopened.firstMatch.value as? String, "After the table")
  }
  @MainActor func testFolderCanBeCreatedWithoutPairingOrNetwork() {
    let app = launch()
    // The default fixture's only creatable workspace is this device's local one.
    let newFolder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "action-new-folder-"))
    XCTAssertTrue(newFolder.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(newFolder.count, 1)
    XCTAssertEqual(newFolder.firstMatch.label, "New Folder")
    reveal(newFolder.firstMatch, in: app)
    newFolder.firstMatch.tap()
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
    let created = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder-' AND label BEGINSWITH %@", name)).firstMatch
    XCTAssertTrue(created.waitForExistence(timeout: 5))
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


  /// Saves a screenshot when `WOVENMATTER_UI_SCREENSHOT_DIR` is set (review evidence, kept out of Git).
  @MainActor func saveScreenshot(_ name: String) {
    guard let directory = ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCREENSHOT_DIR"], !directory.isEmpty else { return }
    try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }

  /// From a phone paired as a member with two Dev Macs that both serve
  /// library history: the New Chat menu lists Quick Chat first, then each Mac
  /// once under its own name with its own agents, and no copied snapshot row.
  @MainActor func testNewChatMenuListsQuickChatFirstAndEachMacOnce() {
    let app = launch(tab: "Home", scenario: "member-macs")
    let air = "0446435c-8e64-440e-b9eb-3c5dadb27e04", mini = "b03923c3-89d1-4f29-910a-b7e3ce7b586c"
    app.buttons["action-new-chat"].tap()
    let quickChat = app.buttons["choose-chat-agent-local:pi-durable-device"]
    XCTAssertTrue(quickChat.waitForExistence(timeout: 5))
    // Review evidence: the whole menu, page by page.
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "choose-chat-agent-")).firstMatch
    for page in 1...3 { sleep(1); saveScreenshot("new-chat-menu-\(page)"); (page == 1 ? row : app).swipeUp() }
    let groups = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chooser-group-"))
    XCTAssertEqual(groups.allElementsBoundByIndex.map(\.label), ["Quick Chat", "James’s MacBook Air (Dev) · worktrees-b8e80bfb02",
      "James’s Mac Mini (Dev) · woven-everywhere"], "Quick Chat leads; each Mac appears once under its own name")
    XCTAssertLessThan(quickChat.frame.minY, app.staticTexts["chooser-group-host"].frame.minY)
    // The library host's own agents, ready by its own report even though its cached host list was stale.
    XCTAssertTrue(app.buttons["choose-chat-agent-host:local:default_agent"].isEnabled)
    XCTAssertTrue(app.buttons["choose-chat-agent-" + air + ":local:codex"].exists, "Codex falls back to the Air's own fresh list")
    let miniAgent = app.buttons["choose-chat-agent-" + mini + ":local:claude_code"]
    reveal(miniAgent, in: app)
    XCTAssertFalse(app.staticTexts["James’s MacBook Air"].exists, "A copied snapshot owner is history, not a workspace")
    XCTAssertFalse(app.staticTexts["Workstation (Dev)"].exists, "An unreachable Linux workspace waits until it is reachable")
  }

  /// Sending to a Mac session shows the message at once, with quiet progress,
  /// while the workspace takes a moment to accept it; the workspace's copy
  /// then replaces it without a duplicate.
  @MainActor func testMessageToAMacSessionAppearsImmediately() {
    let app = launch(tab: "Chats", scenario: "member-macs-send")
    let composer = app.descendants(matching: .any)["chat-composer"].firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    // Tap the editor itself: on iPad the identifier first resolves to the placeholder text.
    let editor = composer.textViews.firstMatch.exists ? composer.textViews.firstMatch : app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("What should we work on next?")
    app.buttons["Send message"].tap()
    let message = app.staticTexts["What should we work on next?"]
    XCTAssertTrue(message.waitForExistence(timeout: 1), "The message appears before the workspace answers")
    XCTAssertTrue(app.staticTexts["chat-send-progress"].exists)
    saveScreenshot("send-pending")
    let settled = NSPredicate(format: "exists == false")
    expectation(for: settled, evaluatedWith: app.staticTexts["chat-send-progress"])
    waitForExpectations(timeout: 10)
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "What should we work on next?")).count, 1)
    saveScreenshot("send-settled")
  }


  /// A fresh install that was never paired (an App Review device has no Mac):
  /// Quick Chat leads with its setup prompt, notes and folders work on the
  /// phone, Mac-only pages stay out of the way, and pairing is offered calmly.
  @MainActor func testFreshInstallWithoutPairingIsCompleteAndCalm() {
    let app = launch(tab: "Home", scenario: "standalone")
    // The app names the device it runs on: "this iPad" in the iPad run.
    let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    let connect = app.buttons["home-connect-mac"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["home-connect-mac-caption"].label.contains("Everything on this \(device) is kept"))
    XCTAssertTrue(app.buttons["open-calendar"].exists)
    XCTAssertFalse(app.buttons["open-scheduled-tasks"].exists, "Scheduled tasks run on a Mac or Linux workspace")
    XCTAssertFalse(app.buttons["open-databases"].exists)
    XCTAssertFalse(app.staticTexts["workspace-action-error"].exists)
    saveScreenshot("standalone-home")

    // Quick Chat opens with the provider sign-in prompt, which leads to Connections and web search.
    app.buttons["launch-agent-local:pi-durable-device"].tap()
    let setup = app.buttons["quick-chat-setup"]
    XCTAssertTrue(setup.waitForExistence(timeout: 5))
    XCTAssertEqual(setup.label, "Sign in to a model provider to use Quick Chat")
    XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].firstMatch.exists)
    saveScreenshot("standalone-quick-chat")
    setup.tap()
    XCTAssertTrue(app.navigationBars[device + " Connections"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Web search"].exists)
    saveScreenshot("standalone-connections")

    // A note is created, edited and saved on this device, then deleted there.
    app.buttons["tab-home"].tap()
    app.buttons["action-new-note"].firstMatch.tap()
    let title = app.descendants(matching: .any)["note-title"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    title.typeText(" for the trip")
    let body = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-' ")).firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 5))
    body.tap(); body.typeText("Pack the charger.")
    let saved = app.buttons["note-save-state"]
    expectation(for: NSPredicate(format: "label CONTAINS 'Saved on this device'"), evaluatedWith: saved)
    waitForExpectations(timeout: 10)
    saveScreenshot("standalone-note")
    app.buttons["Note actions"].tap()
    app.buttons["Details, move and delete"].tap()
    let delete = app.buttons["note-delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Move to Trash"].exists)
    delete.tap()
    let confirm = app.sheets.buttons["Delete note"]
    if confirm.waitForExistence(timeout: 2) { confirm.tap() }
    else { app.buttons.matching(NSPredicate(format: "label == 'Delete note' AND identifier != 'note-delete'")).firstMatch.tap() }
    XCTAssertTrue(app.buttons["tab-folders"].waitForExistence(timeout: 5))
    app.buttons["tab-folders"].tap()
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'for the trip'")).firstMatch.exists, "The deleted note is gone")

    // Folders: a folder is created here, and remote workspaces explain pairing instead of an outage.
    let remote = app.staticTexts["folders-remote-empty"]
    XCTAssertTrue(remote.waitForExistence(timeout: 5))
    XCTAssertTrue(remote.label.hasPrefix("Pair with your Mac"))
    let newFolder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "action-new-folder-")).firstMatch
    reveal(newFolder, in: app)
    newFolder.tap()
    let field = app.alerts["New folder"].textFields["Folder name"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap(); field.typeText("Trips")
    app.alerts["New folder"].buttons["Create"].tap()
    XCTAssertTrue(app.staticTexts["This folder is empty. Add a note or start a chat."].waitForExistence(timeout: 5))
    saveScreenshot("standalone-folder")

    // Library explains what pairing adds instead of showing a disabled search.
    app.buttons["tab-home"].tap()
    app.buttons["open-library"].tap()
    XCTAssertTrue(app.staticTexts["library-standalone"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Search"].exists)

    // Analytics say plainly that nothing is sent without a paired Mac.
    app.buttons["tab-settings"].tap()
    app.buttons["General"].tap()
    let analytics = app.staticTexts["analytics-explanation"]
    XCTAssertTrue(analytics.waitForExistence(timeout: 5))
    XCTAssertTrue(analytics.label.hasPrefix("Nothing is sent while this \(device) isn’t paired"))
    saveScreenshot("standalone-general")
  }

  /// A Quick Chat timer made on a phone that was never paired shows in its calendar.
  @MainActor func testStandaloneTimerAppearsInCalendar() {
    let app = launch(tab: "Calendar", scenario: "standalone-timer")
    XCTAssertTrue(app.staticTexts["Stretch"].waitForExistence(timeout: 10))
    saveScreenshot("standalone-timer-calendar")
  }
}
