import XCTest
import UIKit
import WovenMatterCompanion
@testable import WovenMatterMobileApp

@MainActor
final class ConversationPresentationTests: XCTestCase {
  func testStructuredToolsUseDesktopGroupingAndFailuresRemainVisible() throws {
    let projection = #"{"id":"tool","kind":"tool","title":"read_file","toolName":"read_file","status":"failed","position":2,"locations":[],"changes":[],"planEntries":[],"rawInputJSON":"{}","content":"Not found"}"#
    let transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id:"u", conversationID:"c", runID:"r", role:"user", content:"Inspect", sequence:0),
      .init(id:"comment", conversationID:"c", runID:"r", role:"assistant", content:"I’ll look.", sequence:1),
      .init(id:"answer", conversationID:"c", runID:"r", role:"assistant", content:"## Result\n\nThe file is absent.", sequence:4)
    ], activities:[.init(id:"tool", runID:"r", title:"read_file", status:"failed", projectionJSON:projection, sequence:2)],
      runs:[.init(id:"r", status:"completed")])
    let rows = MobileConversationProjection.rows(transcript)
    XCTAssertEqual(rows.count, 2)
    guard case .turn(let turn) = rows.last?.content else { return XCTFail("Expected one assistant turn") }
    XCTAssertEqual(turn.content, "## Result\n\nThe file is absent.")
    XCTAssertEqual(turn.commentaryIDs, ["comment"])
    XCTAssertEqual(turn.timeline.entries.count, 2)
    XCTAssertEqual(turn.timeline.foldedEntries.count, 1, "Desktop failure visibility survives folding")
  }
  func testMarkdownUsesOneSelectableNativeSurfaceAndDesktopBlocks() throws {
    let content = "# Heading\n\n- One\n  - Two\n\n> Quote\n\n```swift\nlet n = 1\n```\n\n| Name | Value |\n| --- | --- |\n| A | **B** |"
    let document = ConversationMarkdownDocument(content)
    XCTAssertEqual(document.blocks.count, 5)
    let view = ConversationResponseNativeTextView()
    view.apply(content: content, document: document, isStreaming: false, typeSize: "large")
    XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isScrollEnabled)
    XCTAssertFalse(view.text.contains("```")); XCTAssertFalse(view.text.contains("**B**"))
    XCTAssertTrue(view.text.contains("Heading")); XCTAssertTrue(view.text.contains("let n = 1"))
    XCTAssertGreaterThan(view.fittingSize(width: 340).height, 100)
    var tableCells = 0
    view.textStorage.enumerateAttribute(.paragraphStyle, in: NSRange(location:0, length:view.textStorage.length)) { value, _, _ in
      if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty { tableCells += 1 }
    }
    XCTAssertGreaterThanOrEqual(tableCells, 4)
    view.selectedRange = NSRange(location:0, length:7)
    view.apply(content: content + "\n\nMore", document:nil, isStreaming:true, typeSize:"large")
    XCTAssertEqual(view.selectedRange, NSRange(location:0, length:7))
  }
  func testDisclosuresSurviveSwitchingConversations() {
    let states = MobileConversationStates()
    states.state(for: "first").setRunExpanded("r", true)
    states.state(for: "first").setExpanded("tool", true)
    states.state(for: "second").setRunExpanded("r", false)
    XCTAssertTrue(states.state(for: "first").isRunExpanded("r", default: false))
    XCTAssertTrue(states.state(for: "first").isExpanded("tool"))
    XCTAssertFalse(states.state(for: "second").isRunExpanded("r", default: true))
    XCTAssertFalse(states.state(for: "second").isExpanded("tool"))
  }
  func testToolOnlyTurnAppearsBeforeAnyAssistantMessage() {
    let activity = CompanionActivity(id:"call", runID:"r", title:"list_files", status:"running", sequence:1)
    let transcript = CompanionTranscript(conversationID:"c", messages:[
      .init(id:"u", conversationID:"c", runID:"r", role:"user", content:"Inspect", sequence:0)
    ], activities:[activity], activeRunID:"request", runs:[.init(id:"r", status:"running")])
    let rows = MobileConversationProjection.rows(transcript)
    XCTAssertEqual(rows.count, 2)
    guard case .turn(let turn) = rows.last?.content else { return XCTFail("Expected running work") }
    XCTAssertEqual(turn.run.status, "running"); XCTAssertTrue(turn.content.isEmpty)
    XCTAssertTrue(turn.timeline.hasVisibleActivities)
  }
}
