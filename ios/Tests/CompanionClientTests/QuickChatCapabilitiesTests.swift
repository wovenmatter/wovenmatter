import XCTest
@testable import CompanionClient

final class QuickChatCapabilitiesTests: XCTestCase {
  func testSavedGrantsCannotEnableCodingAutomationOrScheduling() {
    for name in ["execute_command", "codemode", "subagent", "write_file", "woven_goals_set", "woven_timers_add", "woven_sessions_create", "woven_executor_execute", "woven_browser_use", "woven_computer_use"] {
      XCTAssertFalse(QuickChatCapabilities.enabled(name, selection: [name]))
      XCTAssertFalse(QuickChatCapabilities.enabled(name, selection: nil))
      XCTAssertFalse(QuickChatCapabilities.toolNames.contains(name))
    }
    XCTAssertTrue(QuickChatCapabilities.enabled("woven_notes_create", selection: nil))
    XCTAssertTrue(QuickChatCapabilities.enabled("web_search", selection: nil))
    XCTAssertFalse(QuickChatCapabilities.enabled("woven_notes_create", selection: ["read_note"]))
    XCTAssertTrue(QuickChatCapabilities.enabled("woven_notes_read", selection: ["read_note"]))
    XCTAssertFalse(QuickChatCapabilities.enabled("web_search", selection: []))
  }
}
