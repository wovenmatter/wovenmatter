import XCTest

/// A fresh install with no machine connected: Quick Chat is ready to use and
/// says what it needs, and the four tabs are there, switch, and each stands
/// on its own without a Mac.
@MainActor
final class MobileShellUITests: XCTestCase {
    func testFreshInstallShowsTabsAndQuickChat() {
        let app = XCUIApplication()
        app.launch()
        let any = app.descendants(matching: .any)

        XCTAssertTrue(any["chat-empty-state"].waitForExistence(timeout: 10))
        XCTAssertTrue(any["chat-composer"].exists)
        XCTAssertTrue(any["quick-chat-setup"].waitForExistence(timeout: 10), "Quick Chat's sign-in notice")

        let pages = ["bots": "bots-empty-state", "folders": "folders-connect-mac", "artifacts": "artifacts-new",
                     "chat": "chat-empty-state"]
        for tab in ["bots", "folders", "artifacts", "chat"] {
            let button = app.buttons["tab-\(tab)"]
            XCTAssertTrue(button.exists, "tab-\(tab)")
            button.tap()
            XCTAssertTrue(button.isSelected, "tab-\(tab) selected")
            XCTAssertTrue(any[pages[tab]!].waitForExistence(timeout: 5), "\(tab) shows \(pages[tab]!)")
            XCTAssertTrue(any[pages[tab]!].isHittable, "\(tab) shows \(pages[tab]!) in front")
        }
    }
}
