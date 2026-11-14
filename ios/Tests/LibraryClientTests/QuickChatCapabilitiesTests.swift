import XCTest
@testable import LibraryClient

final class QuickChatCapabilitiesTests: XCTestCase {
  func testSavedGrantsCannotEnableCodingAutomationOrScheduledAgentWork() {
    for name in ["execute_command", "codemode", "subagent", "write_file", "fetch_url", "woven_goals_set", "woven_sessions_create", "woven_executor_execute",
                 "woven_browser_use", "woven_computer_use", "woven_history_search", "woven_library_read"] {
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

  func testQuickChatCanReadAndEditPagesWithTheNotesGrant() {
    let pages = ["woven_pages_list", "woven_pages_read", "woven_pages_create", "woven_pages_update", "woven_pages_add_component",
                 "woven_pages_update_component", "woven_pages_move_component", "woven_pages_remove_component",
                 "woven_pages_link_session", "woven_pages_unlink_session"]
    for name in pages {
      XCTAssertTrue(QuickChatCapabilities.toolNames.contains(name), name)
      XCTAssertTrue(QuickChatCapabilities.enabled(name, selection: ["woven_notes"]), name)
      XCTAssertFalse(QuickChatCapabilities.enabled(name, selection: ["woven_timers"]), name)
    }
  }

  func testTimersCalendarAndClockStayInsideTheBoundary() {
    for name in ["woven_timers_create", "woven_timers_list", "woven_timers_remove", "woven_calendar_create", "woven_calendar_list", "clock", "ask_user"] {
      XCTAssertTrue(QuickChatCapabilities.toolNames.contains(name), name)
      XCTAssertTrue(QuickChatCapabilities.enabled(name, selection: nil), name)
    }
    XCTAssertTrue(QuickChatCapabilities.enabled("woven_timers_create", selection: ["woven_timers"]))
    XCTAssertFalse(QuickChatCapabilities.enabled("woven_timers_create", selection: ["woven_notes"]))
    XCTAssertFalse(QuickChatCapabilities.enabled("woven_calendar_create", selection: ["woven_timers"]))
    XCTAssertTrue(QuickChatCapabilities.enabled("woven_timers", selection: ["woven_timers_list"]), "A partial grant is described by its group")
    XCTAssertTrue(QuickChatCapabilities.enabled("clock", selection: []), "Reading the time needs no grant")
    XCTAssertEqual(QuickChatCapabilities.options.map(\.id), ["woven_notes", "woven_timers", "woven_calendar", "quick_chat_web"])
  }
}
