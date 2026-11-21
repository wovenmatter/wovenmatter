import XCTest

/// A fresh install with no machine connected: the four tabs are there and
/// switch, and Quick Chat is ready to use.
@MainActor
final class MobileShellUITests: XCTestCase {
    func testFreshInstallShowsTabsAndQuickChat() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["chat-empty-state"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["chat-composer"].exists)

        for tab in ["bots", "folders", "artifacts", "chat"] {
            let button = app.buttons["tab-\(tab)"]
            XCTAssertTrue(button.exists, "tab-\(tab)")
            button.tap()
            XCTAssertTrue(button.isSelected, "tab-\(tab) selected")
        }
        XCTAssertTrue(app.descendants(matching: .any)["chat-empty-state"].isHittable)
    }
}
