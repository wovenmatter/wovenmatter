import XCTest
import UIKit
import SwiftUI
import WovenMatterCompanion
@testable import WovenMatterMobileApp

@MainActor
final class ConversationPresentationTests: XCTestCase {
  func testDarkThemeUsesSharedColorsWithoutChangingSavedNoteColors() {
    XCTAssertEqual(DashboardTheme.allCases.map(\.rawValue), ["green", "cognac", "dark"])
    XCTAssertEqual(DashboardTheme.dark.colorScheme, .dark)
    XCTAssertEqual(DashboardTheme.green.colorScheme, .light)
    XCTAssertEqual(DashboardTheme.cognac.colorScheme, .light)
    let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
    XCTAssertEqual(DashboardColors.documentColorHex(DashboardColors.foreground), "#0A1F16")
    let ink = DashboardColors.noteForeground(DashboardColors.color(0x111827))
    let highlight = DashboardColors.noteBackground(DashboardColors.color(0xFFEB94))
    XCTAssertEqual(DashboardColors.documentColorHex(ink), "#111827")
    XCTAssertEqual(DashboardColors.documentColorHex(highlight), "#FFEB94")
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(ink.resolvedColor(with: darkTraits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertGreaterThan(red, 0.5)
    XCTAssertTrue(highlight.resolvedColor(with: darkTraits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertLessThan(red, 0.4)
  }

  func testDarkResponsePreservesSelectionAndReturnsToLight() {
    let view = ConversationResponseNativeTextView()
    let content = "An unchanged response with **formatting**."
    view.apply(content: content, document: nil, isStreaming: false, typeSize: .large)
    view.selectedRange = NSRange(location: 0, length: 7)
    for scheme in [ColorScheme.dark, .light] {
      view.apply(content: content, document: nil, isStreaming: false, typeSize: .large, colorScheme: scheme)
      XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 7))
      XCTAssertEqual(view.overrideUserInterfaceStyle, scheme == .dark ? .dark : .light)
      let color = view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! UIColor
      let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
      var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
      XCTAssertTrue(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
      if scheme == .dark { XCTAssertGreaterThan(red, 0.7) }
      else { XCTAssertLessThan(red, 0.1) }
    }
  }

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

  func testLiveResponseUsesSharedBoundariesAndTerminalRunFlushesUnfinishedText() throws {
    let partial = "Ready paragraph.\n\n```swift\nlet unfinished ="
    var transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id: "answer", conversationID: "c", runID: "r", role: "assistant",
        content: partial, status: "streaming", sequence: 1)
    ], activeRunID: "r", runs: [.init(id: "r", status: "running")])
    let live = try projectedTurn(transcript)
    XCTAssertEqual(live.content, "Ready paragraph.\n\n")
    XCTAssertTrue(live.isStreaming)
    for status in ["completed", "interrupted", "cancelled", "failed"] {
      transcript.runs = [.init(id: "r", status: status)]
      let settled = try projectedTurn(transcript)
      XCTAssertEqual(settled.content, partial, "Terminal \(status) must flush even if message/active flags lag")
      XCTAssertFalse(settled.isStreaming)
      XCTAssertEqual(settled.run.status, status)
    }
  }

  func testHiddenWorkCannotDisplaceFinalReply() throws {
    let activities: [AgentRunActivity] = [
      .init(id: "checklist", kind: .plan, planEntries: [.init(content: "Done", status: "completed")]),
      .init(id: "control", kind: .tool, status: "completed", toolName: "update_plan"),
      .init(id: "files", kind: .fileChange),
      .init(id: "empty-thought", kind: .thought, content: "  \n")
    ]
    let transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id: "answer", conversationID: "c", runID: "r", role: "assistant", content: "Final answer", sequence: 1)
    ], activities: try activities.enumerated().map { index, activity in
      try transported(activity, sequence: Int64(index + 2))
    }, runs: [.init(id: "r", status: "completed")])
    let turn = try projectedTurn(transcript)
    XCTAssertEqual(turn.content, "Final answer")
    XCTAssertTrue(turn.commentaryIDs.isEmpty)
    XCTAssertFalse(turn.timeline.hasVisibleActivities)
  }

  func testLegacyToolAndReasoningKeepCommentaryInChronologicalWork() throws {
    let thought = AgentRunActivity(id: "reasoning", kind: .thought, status: "completed",
      content: "Checking the result", position: 3)
    let transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id: "comment", conversationID: "c", runID: "r", role: "assistant", content: "I’ll inspect", sequence: 1),
      .init(id: "tool", conversationID: "c", runID: "r", role: "toolResult", content: "file", sequence: 2),
      .init(id: "answer", conversationID: "c", runID: "r", role: "assistant", content: "Found it", sequence: 4)
    ], activities: [try transported(thought, sequence: 3)], runs: [.init(id: "r", status: "interrupted")])
    let turn = try projectedTurn(transcript)
    XCTAssertEqual(turn.content, "Found it")
    XCTAssertEqual(turn.commentaryIDs, ["comment"])
    XCTAssertEqual(turn.timeline.entries.map(\.id), ["commentary:comment", "group:tool"])
    guard case .group(let group) = turn.timeline.entries.last?.content else { return XCTFail("Expected tool/reasoning group") }
    XCTAssertEqual(group.activities.map(\.id), ["tool", "reasoning"])
  }

  func testDesktopCheckpointsPartitionCumulativeResponseWithoutDuplication() throws {
    let comment = "I’ll inspect."
    let activity = AgentRunActivity(id: "segment", kind: .assistant, content: comment,
      assistantMessageID: "answer", assistantCheckpoint: .init(comment), position: 1)
    let tool = AgentRunActivity(id: "tool", kind: .tool, title: "read_file", status: "completed", position: 2)
    let transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id: "answer", conversationID: "c", runID: "r", role: "assistant",
        content: comment + "Final answer", sequence: 0)
    ], activities: [try transported(activity, sequence: 1), try transported(tool, sequence: 2)],
      runs: [.init(id: "r", status: "completed")])
    let turn = try projectedTurn(transcript)
    XCTAssertEqual(turn.content, "Final answer")
    XCTAssertEqual(turn.commentaryIDs, ["segment"])
    XCTAssertEqual(turn.timeline.entries.map(\.id), ["commentary:segment", "group:tool"])
  }

  func testLateToolResultAndClearedActivityDoNotMoveFinalReply() throws {
    let start = AgentRunActivity(id: "tool", kind: .tool, title: "read_file", status: "running", position: 1)
    let result = AgentRunActivity(id: "tool", kind: .tool, status: "completed", position: 1)
    let cleared = AgentRunActivity(id: "cleared", kind: .tool, phase: "clear", position: 4)
    let transcript = CompanionTranscript(conversationID: "c", messages: [
      .init(id: "answer", conversationID: "c", runID: "r", role: "assistant", content: "Final answer", sequence: 2)
    ], activities: [try transported(start, sequence: 1), try transported(result, sequence: 3),
                   try transported(cleared, sequence: 4)], runs: [.init(id: "r", status: "completed")])
    let turn = try projectedTurn(transcript)
    XCTAssertEqual(turn.content, "Final answer")
    XCTAssertTrue(turn.commentaryIDs.isEmpty)
    XCTAssertEqual(turn.timeline.entries.map(\.id), ["group:tool"])
  }

  func testMobileToolProjectionRetainsSpecificActionAndLabelBehindGenericTransportKinds() throws {
    let fixtures: [(String, String, ConversationToolAction, String)] = [
      ("other", "web_search", .webSearch, "Searching the web"),
      ("execute", "web_search", .webSearch, "Searching the web"),
      ("other", "woven_browser_use", .browser, "Using the browser"),
      ("execute", "woven_browser_use", .browser, "Using the browser"),
      ("other", "bash", .command, "Running bash"),
      ("execute", "bash", .command, "Running bash")
    ]
    for (transportKind, title, action, label) in fixtures {
      let activity = AgentRunActivity(id: "tool", kind: .tool, title: title,
        status: "running", toolName: transportKind)
      for structured in [true, false] {
        var record = try transported(activity, sequence: 1)
        if !structured { record.projectionJSON = nil }
        let transcript = CompanionTranscript(conversationID: "c", activities: [record],
          runs: [.init(id: "r", status: "running")])
        let turn = try projectedTurn(transcript)
        guard case .group(let group) = turn.timeline.entries.first?.content else {
          return XCTFail("Expected shared tool presentation for \(title)")
        }
        XCTAssertEqual(group.action, action, "\(transportKind) must retain the \(title) semantic icon")
        XCTAssertEqual(group.liveLabel(runIsActive: true), label)
        XCTAssertTrue(group.hasActiveActivity, "Static tool presentation must preserve execution state")
      }
    }
  }

  private func projectedTurn(_ transcript: CompanionTranscript) throws -> MobileConversationProjection.Turn {
    let row = try XCTUnwrap(MobileConversationProjection.rows(transcript).last)
    guard case .turn(let turn) = row.content else { throw NSError(domain: "Expected assistant turn", code: 1) }
    return turn
  }

  private func transported(_ activity: AgentRunActivity, sequence: Int64) throws -> CompanionActivity {
    .init(id: activity.id, runID: "r", title: activity.title ?? "", status: activity.status ?? "completed",
      projectionJSON: String(decoding: try JSONEncoder().encode(activity), as: UTF8.self), sequence: sequence)
  }
}
