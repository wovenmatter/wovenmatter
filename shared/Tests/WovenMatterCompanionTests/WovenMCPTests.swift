import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Woven MCP contract")
struct WovenMCPTests {
  private let requestID = "11111111-1111-4111-8111-111111111111"

  @Test func boardToolsShareTheNotesGroupAndMapToItsCommands() throws {
    let expected = ["list", "create", "read", "update", "add_item", "update_item", "remove_item", "link_session", "edit_layout"].map { "woven_boards_" + $0 }
    let tools = WovenMCPCatalog.tools.filter { $0.name.hasPrefix("woven_boards_") }
    #expect(Set(tools.map(\.name)) == Set(expected))
    #expect(tools.allSatisfy { $0.group == .notes })
    #expect(Set(tools.filter { !$0.isMutation }.map(\.name)) == ["woven_boards_list", "woven_boards_read"])
    #expect(!WovenMCPCatalog.tools.contains { $0.name == "woven_notes_canvas" })
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["notes", "canvas", "--note-id", "n", "--json", "[]"]) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_notes_create", arguments: .object(["title": .string("B"), "kind": .string("canvas")])) }

    let request = try WovenMCPCatalog.request(name: "woven_boards_update_item", arguments: .object([
      "boardID": .string("b"), "itemID": .string("i"), "itemRevision": .string("r"), "status": .string("done"),
      "outcome": .string(""), "clearReview": .bool(true), "requestID": .string(requestID)]))
    let command = try WovenMatterToolCommand(request.arguments)
    #expect(command.group == .notes && command.action == "board-update-item" && command.isBoardCommand && command.isMutation)
    #expect(command.options["note-id"] == "b" && command.options["id"] == "i" && command.options["item-revision"] == "r")
    #expect(command.options["outcome"] == "" && command.options["clear-review"] == "true")
    #expect(request.requestID == requestID)
    for action in ["list", "read"] {
      let read = try WovenMatterToolCommand(["boards", action] + (action == "read" ? ["--note-id", "b"] : []))
      #expect(read.group == .notes && !read.isMutation)
    }
    let placement = try WovenMCPCatalog.request(name: "woven_boards_add_item", arguments: .object([
      "boardID": .string("b"), "placement": .object(["x": .number(-20), "y": .number(5), "width": .number(360), "height": .number(300)])]))
    #expect(try WovenMatterToolCommand(placement.arguments).options["json"]?.contains("-20") == true)
  }

  @Test func boardToolsAcceptNoProvenanceAndRequireTheirRevisions() throws {
    let base: [String: GatewayJSONValue] = ["boardID": .string("b"), "itemID": .string("i"), "itemRevision": .string("r")]
    for forged in ["updatedBy", "createdBy", "actor", "updatedAt", "createdAt", "caller", "conversationID"] {
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_boards_update_item", arguments: .object(base.merging([forged: .string("forged")]) { $1 }))
      }
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_boards_add_item", arguments: .object(["boardID": .string("b"), forged: .string("forged")]))
      }
    }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_boards_update_item", arguments: .object(["boardID": .string("b"), "itemID": .string("i"), "status": .string("done")])) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_boards_update", arguments: .object(["boardID": .string("b"), "title": .string("T")])) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_boards_edit_layout", arguments: .object(["boardID": .string("b"), "edits": .array([])])) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_boards_update_item", arguments: .object(base.merging(["status": .string("started")]) { $1 })) }
  }

  /// Linux reads this file directly. A stale copy would silently hide tools there.
  @Test func bundledLinuxCatalogMatchesTheCanonicalCatalog() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "remote/src/woven-mcp-tools.json")
    let bundled = try JSONDecoder().decode([WovenMCPToolDefinition].self, from: Data(contentsOf: file))
    #expect(bundled == WovenMCPCatalog.tools)
  }

  @Test func computerAndBrowserUseNamesAndCuaTargetsAreCanonical() throws {
    let names = Set(WovenMCPCatalog.tools.map(\.name))
    #expect(names.contains("woven_browser_use") && names.contains("woven_browser_use_cancel"))
    #expect(names.contains("woven_computer_use") && names.contains("woven_computer_use_cancel"))
    #expect(WorkspaceToolGroup.computer.automationCancelToolName == "woven_computer_use_cancel")
    #expect(WorkspaceToolGroup.browser.automationCancelToolName == "woven_browser_use_cancel")
    #expect(!names.contains("woven_" + "computer") && !names.contains("woven_" + "browser"))
    let request = try WovenMCPCatalog.request(name: "woven_computer_use", arguments: .object([
      "action": .string("snapshot"), "pid": .number(7), "windowID": .number(9), "treeFormat": .string("elements")]))
    let command = try WovenMatterToolCommand(request.arguments)
    #expect(command.group == .computer && command.action == "call")
    let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.required("json").utf8))
    #expect(input.objectValue?["windowID"] == .number(9))
    for key in ["session", "endpoint", "socket", "screenshot_out_file", "prompt"] {
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_computer_use", arguments: .object(["action": .string("apps"), key: .string("forged")]))
      }
    }
    let cancel = try WovenMCPCatalog.request(name: "woven_computer_use_cancel", arguments: .object(["id": .string("all")]))
    #expect(try WovenMatterToolCommand(cancel.arguments).group == .computer)
  }

  @Test func inputAuthorityAndSchemaValidation() throws {
    for extra in ["callerID", "contextID", "file", "arguments", "bearerToken"] {
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_goals_get", arguments: .object([extra: .string("forged")]))
      }
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_notes_read", arguments: .object(["noteID": .string("n"), "characters": .number(65_537)]))
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_notes_read", arguments: .object(["noteID": .number(1)]))
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_goals_set", arguments: .object(["objective": .string("goal"), "requestID": .string("not-a-uuid")]))
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_browser_use", arguments: .object(["action": .string("unknown")]))
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_goals_set", arguments: .object([:]))
    }
  }

  @Test func htmlContractMapsPreparedPagesWithoutMakingPublicationReplayable() throws {
    let render = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_html_render" })
    let preview = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_html_preview" })
    #expect(render.inputSchema.objectValue?["properties"]?.objectValue?["html"]?.objectValue?["maxLength"] == .number(512_000))
    #expect(render.annotations.objectValue?["idempotentHint"] == .bool(false))
    #expect(preview.annotations.objectValue?["idempotentHint"] == .bool(true))
    let html = "<img src='data:image/png;base64," + String(repeating: "A", count: 600_000) + "'>"
    let request = try WovenMCPCatalog.request(name: render.name, arguments: .object(["html": .string(html), "title": .string("Chart"), "height": .number(160)]))
    let command = try WovenMatterToolCommand(request.arguments)
    let page = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.required("json").utf8))
    #expect(command.group == .html)
    #expect(page.objectValue?["action"] == .string("render"))
    #expect(page.objectValue?["html"] == .string(html))
    let message: GatewayJSONValue = .object(["method": .string("tools/call"), "params": .object(["name": .string(render.name)])])
    #expect(WovenMCPServer.maximumRequestBytes(for: message) == 40 * 1024 * 1024)
    #expect(WovenMCPServer.maximumRequestBytes(for: .object(["method": .string("tools/list")])) == 4 * 1024 * 1024)
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: render.name, arguments: .object(["html": .string("<p>Chart</p>"), "title": .string("Chart"), "height": .number(160), "conversationID": .string("forged")]))
    }
  }

  @Test func toolVisibilityAndAuthorizationPrecedeDispatch() async throws {
    let list = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list")]), allowedTools: ["woven_goals_get"]) { _ in .init() }
    #expect(list?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == 1)
    let denied = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("call"), "method": .string("tools/call"), "params": .object(["name": .string("woven_computer_use"), "arguments": .object(["action": .string("screenshot")])])]), allowedTools: ["woven_goals_get"]) { _ in
      Issue.record("A hidden tool must not dispatch")
      return .init()
    }
    #expect(denied?.objectValue?["error"]?.objectValue?["code"] == .number(-32602))
  }

  @Test func browserProfileIsValidatedAndForwarded() throws {
    let request = try WovenMCPCatalog.request(name: "woven_browser_use", arguments: .object(["action": .string("tabs"), "profile": .string("work-2")]))
    #expect(request.arguments.contains(where: { $0.contains("work-2") }))
    for profile in ["../escape", "", "MixedCase", String(repeating: "a", count: 33)] {
      #expect(throws: (any Error).self) {
        try WovenMCPCatalog.request(name: "woven_browser_use", arguments: .object(["action": .string("tabs"), "profile": .string(profile)]))
      }
    }
  }
}
