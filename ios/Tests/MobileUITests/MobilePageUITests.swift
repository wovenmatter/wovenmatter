import XCTest

/// Page editing on iPhone and iPad, against the `page` fixture: text, a task,
/// a "Packing" section with a child, a table and an embedded original note.
extension MobileUITests {
  @MainActor func newAsset(_ kind: String, in app: XCUIApplication) {
    let menu = app.buttons["action-new-asset"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    let item = app.buttons[kind].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "New Asset offers \(kind)")
    item.tap()
  }
  @MainActor func pageText(_ id: String, in app: XCUIApplication) -> XCUIElement { app.textViews["page-text-\(id)"] }
  @MainActor func pageTexts(in app: XCUIApplication) -> XCUIElementQuery {
    app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'page-text-'"))
  }
  @MainActor func waitForPageText(_ value: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
    let element = pageTexts(in: app).matching(NSPredicate(format: "value == %@", value)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "The Page shows “\(value)”")
    return element
  }
  /// Places the caret after the existing text, then types.
  @MainActor func append(_ text: String, to element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    XCTAssertTrue(waitForKeyboardFocus(element))
    element.typeText(text)
  }
  @MainActor func componentAction(_ action: String, for id: String, in app: XCUIApplication) {
    let menu = app.buttons["page-component-actions-\(id)"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    let item = app.buttons[action].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "Component actions offer \(action)")
    item.tap()
  }
  @MainActor func addComponent(_ kind: String, in app: XCUIApplication) {
    app.buttons["page-add-component"].firstMatch.tap()
    let item = app.buttons[kind].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "Add component offers \(kind)")
    item.tap()
  }
  @MainActor func waitUntilSaved(_ app: XCUIApplication) {
    expectation(for: NSPredicate(format: "label CONTAINS 'Saved on this device'"), evaluatedWith: app.buttons["note-save-state"])
    waitForExpectations(timeout: 10)
  }
  @MainActor func relaunch(_ app: XCUIApplication) {
    app.terminate()
    app.launchEnvironment["WOVENMATTER_UI_TAB"] = "Notes"
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["note-title"].firstMatch.waitForExistence(timeout: 10))
  }

  @MainActor func testPageTextTasksAndDetailsPersist() {
    let app = launch(tab: "Notes", scenario: "page")
    let intro = pageText("page-intro", in: app)
    XCTAssertTrue(intro.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Page · read only · edit on your Mac"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["page-purpose"].firstMatch.exists)
    append(" Leave Friday.", to: intro)
    XCTAssertEqual(intro.value as? String, "Plan the weekend trip. Leave Friday.")
    // Saved Page writing keeps its undo history.
    waitUntilSaved(app)
    app.buttons["note-undo"].tap()
    expectation(for: NSPredicate(format: "value == 'Plan the weekend trip.'"), evaluatedWith: intro)
    waitForExpectations(timeout: 5)
    app.buttons["note-redo"].tap()
    expectation(for: NSPredicate(format: "value == 'Plan the weekend trip. Leave Friday.'"), evaluatedWith: intro)
    waitForExpectations(timeout: 5)

    // The checkbox is a toggle named by its task.
    let toggle = app.switches["page-task-toggle-page-task"]
    XCTAssertTrue(toggle.exists)
    XCTAssertEqual(toggle.label, "Book the train")
    XCTAssertEqual(toggle.value as? String, "0")
    toggle.tap()
    expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
    waitForExpectations(timeout: 5)

    // A new task goes after the selected component and takes the caret.
    pageText("page-task", in: app).tap()
    addComponent("Task", in: app)
    let created = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'page-task-toggle-' AND identifier != 'page-task-toggle-page-task'")).firstMatch
    XCTAssertTrue(created.waitForExistence(timeout: 5))
    let createdID = String(created.identifier.dropFirst("page-task-toggle-".count))
    let createdText = pageText(createdID, in: app)
    XCTAssertTrue(waitForKeyboardFocus(createdText), "Typing starts in the new task")
    app.typeText("Pack snacks")
    XCTAssertEqual(createdText.value as? String, "Pack snacks")
    XCTAssertLessThan(pageText("page-task", in: app).frame.minY, createdText.frame.minY)

    // Component details: assignment is a label on the task.
    componentAction("Component details", for: "page-task", in: app)
    let assignee = app.textFields["page-details-assignee"]
    XCTAssertTrue(assignee.waitForExistence(timeout: 5))
    assignee.tap(); assignee.typeText("Jordan")
    app.buttons["page-details-done"].tap()
    XCTAssertTrue(app.staticTexts["Jordan"].waitForExistence(timeout: 5), "The task shows its assignee")

    waitUntilSaved(app)
    relaunch(app)
    XCTAssertEqual(pageText("page-intro", in: app).value as? String, "Plan the weekend trip. Leave Friday.")
    XCTAssertEqual(app.switches["page-task-toggle-page-task"].value as? String, "1")
    XCTAssertEqual(pageText(createdID, in: app).value as? String, "Pack snacks")
    XCTAssertTrue(app.switches["page-task-toggle-\(createdID)"].exists)
    XCTAssertTrue(app.staticTexts["Jordan"].exists)
  }

  @MainActor func testPageSectionsTablesAndOriginalsPersist() {
    let app = launch(tab: "Notes", scenario: "page")
    let moved = pageText("page-note-text", in: app)
    XCTAssertTrue(moved.waitForExistence(timeout: 10))
    let rootX = pageText("page-intro", in: app).frame.minX
    XCTAssertEqual(moved.frame.minX, rootX, accuracy: 1)
    XCTAssertGreaterThan(pageText("page-child", in: app).frame.minX, rootX, "Section children are indented")

    componentAction("Move into section above", for: "page-note-text", in: app)
    expectation(for: NSPredicate { _, _ in moved.frame.minX > rootX + 8 }, evaluatedWith: moved)
    waitForExpectations(timeout: 5)
    // Collapsing the section hides what it now holds.
    app.buttons["page-section-toggle-page-section"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: moved)
    waitForExpectations(timeout: 5)
    app.buttons["page-section-toggle-page-section"].tap()
    XCTAssertTrue(moved.waitForExistence(timeout: 5))

    // Edit a table cell, then add a row through the shared table edit.
    let cell = app.buttons["page-cell-page-table-1-1"]
    XCTAssertTrue(cell.exists); XCTAssertEqual(cell.label, "Sam")
    cell.tap()
    let field = app.textFields["page-cell-text"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Alex")
    app.buttons["page-cell-save"].tap()
    expectation(for: NSPredicate(format: "label == 'Alex'"), evaluatedWith: cell)
    waitForExpectations(timeout: 5)
    cell.tap()
    XCTAssertTrue(app.buttons["page-cell-add-row"].waitForExistence(timeout: 5))
    app.buttons["page-cell-add-row"].tap()
    XCTAssertTrue(app.buttons["page-cell-page-table-2-0"].waitForExistence(timeout: 5))

    // A new Note is created on this device and linked as an original.
    app.buttons["page-component-actions-page-embed"].firstMatch.tap()
    app.buttons["Component details"].firstMatch.tap()
    app.buttons["page-details-done"].firstMatch.tap()
    addComponent("New Note", in: app)
    let createdEmbed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'page-open-original-' AND identifier != 'page-open-original-page-embed'")).firstMatch
    XCTAssertTrue(createdEmbed.waitForExistence(timeout: 5))
    let createdEmbedID = createdEmbed.identifier
    XCTAssertTrue(app.staticTexts["Untitled note"].exists)

    waitUntilSaved(app)
    relaunch(app)
    XCTAssertGreaterThan(pageText("page-note-text", in: app).frame.minX, pageText("page-intro", in: app).frame.minX + 8)
    XCTAssertEqual(app.buttons["page-cell-page-table-1-1"].label, "Alex")
    XCTAssertTrue(app.buttons["page-cell-page-table-2-0"].exists)
    let reopenedEmbed = app.buttons[createdEmbedID]
    reveal(reopenedEmbed, in: app)

    // Opening an original uses its own pane.
    let original = app.buttons["page-open-original-page-embed"]
    reveal(original, in: app)
    original.tap()
    let title = app.descendants(matching: .any)["note-title"].firstMatch
    expectation(for: NSPredicate(format: "value == 'Launch Plan'"), evaluatedWith: title)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'note-body-editor-'")).firstMatch.exists)
  }

  @MainActor func testNewPageFromNewAssetMenu() {
    let app = launch(tab: "Notes", scenario: "page")
    XCTAssertTrue(pageText("page-intro", in: app).waitForExistence(timeout: 10))
    newAsset("Page", in: app)
    let title = app.descendants(matching: .any)["note-title"].firstMatch
    expectation(for: NSPredicate(format: "value == 'Untitled Page'"), evaluatedWith: title)
    waitForExpectations(timeout: 5)
    let first = pageTexts(in: app).firstMatch
    XCTAssertTrue(first.waitForExistence(timeout: 5), "An empty Page offers a place to write")
    first.tap()
    first.typeText("First idea")
    _ = waitForPageText("First idea", in: app)
    addComponent("Task", in: app)
    let task = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'page-task-toggle-'")).firstMatch
    XCTAssertTrue(task.waitForExistence(timeout: 5))
    let taskText = pageText(String(task.identifier.dropFirst("page-task-toggle-".count)), in: app)
    XCTAssertTrue(waitForKeyboardFocus(taskText))
    app.typeText("Call the venue")
    XCTAssertEqual(taskText.value as? String, "Call the venue")
    XCTAssertEqual(task.label, "Call the venue")
    waitUntilSaved(app)
    relaunch(app)
    // The fixture Page reopens; the new Page is in the library with its writing.
    app.buttons["tab-folders"].tap()
    let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recent-note-' AND label CONTAINS 'Untitled Page'")).firstMatch
    reveal(recent, in: app)
    recent.tap()
    _ = waitForPageText("First idea", in: app, timeout: 10)
    _ = waitForPageText("Call the venue", in: app)
  }

  /// A Quick Chat tool edit lands while the Page is open and the user is typing.
  @MainActor func testIncomingPageChangeAppearsWithoutLosingTyping() {
    let app = launch(tab: "Notes", scenario: "page-incoming")
    let intro = pageText("page-intro", in: app)
    XCTAssertTrue(intro.waitForExistence(timeout: 10))
    append(" Mid typing", to: intro)
    intro.typeText(" and more")
    let incoming = waitForPageText("Added from Quick Chat", in: app, timeout: 20)
    XCTAssertLessThan(incoming.frame.minY, intro.frame.minY, "The tool added its component at the top")
    expectation(for: NSPredicate(format: "value == 'Plan the weekend trip. Mid typing and more'"), evaluatedWith: intro)
    waitForExpectations(timeout: 10)
    // Typing continues where it was, without another tap.
    XCTAssertTrue(waitForKeyboardFocus(intro))
    app.typeText("!")
    XCTAssertEqual(intro.value as? String, "Plan the weekend trip. Mid typing and more!")
    waitUntilSaved(app)
    relaunch(app)
    _ = waitForPageText("Added from Quick Chat", in: app, timeout: 10)
    XCTAssertEqual(pageText("page-intro", in: app).value as? String, "Plan the weekend trip. Mid typing and more!")
  }
}
