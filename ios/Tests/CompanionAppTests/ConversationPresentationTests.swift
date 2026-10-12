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
    view.apply(content: content, document: document, isStreaming: false, typeSize: .large)
    XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isScrollEnabled)
    XCTAssertFalse(view.text.contains("```")); XCTAssertFalse(view.text.contains("**B**"))
    XCTAssertTrue(view.text.contains("Heading")); XCTAssertTrue(view.text.contains("let n = 1"))
    XCTAssertGreaterThan(view.fittingSize(width: 340).height, 100)
    var tableRows = 0
    view.textStorage.enumerateAttribute(.init("WovenMatterResponseTableRow"), in: NSRange(location:0, length:view.textStorage.length)) { value, _, _ in
      if value != nil { tableRows += 1 }
    }
    XCTAssertEqual(tableRows, 2, "Both table rows retain selectable attributed text on all supported iOS SDKs")
    view.selectedRange = NSRange(location:0, length:7)
    view.apply(content: content + "\n\nMore", document:nil, isStreaming:true, typeSize:.large)
    XCTAssertEqual(view.selectedRange, NSRange(location:0, length:7))
  }
  func testSelectableTableReflowsWithoutDroppingStyledCellContent() throws {
    let content = "| Left | Center | Right |\n| :--- | :---: | ---: |\n| **Bold** and [docs](https://example.com) | LongUnbrokenIdentifier0123456789🍎🍎🍎 | `code` and more words |"
    let view = ConversationResponseNativeTextView()
    view.apply(content: content, document: nil, isStreaming: false, typeSize: .large)
    let wide = view.fittingSize(width: 600)
    let wideText = view.text ?? ""
    let narrow = view.fittingSize(width: 240)
    XCTAssertGreaterThan(narrow.height, wide.height)
    XCTAssertLessThanOrEqual(view.layoutManager.usedRect(for: view.textContainer).maxX, 241,
      "Wrapped columns must stay inside the proposed phone width")
    func visibleScalars(_ text: String) -> [UInt32] {
      text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(\.value).sorted()
    }
    let allCells = "Left Center Right Bold and docs LongUnbrokenIdentifier0123456789🍎🍎🍎 code and more words"
    XCTAssertEqual(visibleScalars(wideText), visibleScalars(allCells))
    XCTAssertEqual(visibleScalars(view.text), visibleScalars(allCells), "Narrow layout must retain every cell character, including wide emoji")
    var hasBold = false, hasCode = false, hasLink = false, alignments: [NSTextAlignment] = []
    view.textStorage.enumerateAttributes(in: NSRange(location: 0, length: view.textStorage.length)) { attributes, _, _ in
      if let font = attributes[.font] as? UIFont {
        hasBold = hasBold || font.fontDescriptor.symbolicTraits.contains(.traitBold)
        hasCode = hasCode || font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
      }
      hasLink = hasLink || (attributes[.link] as? URL)?.absoluteString == "https://example.com"
      if let style = attributes[.paragraphStyle] as? NSParagraphStyle { alignments = style.tabStops.map(\.alignment) }
    }
    XCTAssertTrue(hasBold && hasCode && hasLink)
    XCTAssertEqual(alignments, [.left, .center, .right])
    view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
    XCTAssertEqual(view.selectedRange.length, view.textStorage.length, "The complete table remains one selectable surface")
    XCTAssertEqual(view.fittingSize(width: 600), wide, "Changing orientation must reflow, not keep narrow wrapping")

    UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
      view.apply(content: content, document: nil, isStreaming: false, typeSize: .accessibility5)
      let accessibility = view.fittingSize(width: 240)
      XCTAssertGreaterThanOrEqual(accessibility.height, narrow.height)
      XCTAssertEqual(visibleScalars(view.text), visibleScalars(allCells), "Dynamic Type measurement cannot truncate cell content")
    }
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
