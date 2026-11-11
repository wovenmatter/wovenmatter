import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Woven MCP contract")
struct WovenMCPTests {
  private let requestID = "11111111-1111-4111-8111-111111111111"

  /// Linux's Node server serves the bundled export of this catalog
  /// (`WovenMCPCatalogExport remote/src/woven-mcp-tools.json`); both list the same tools.
  @Test func linuxBundledCatalogMatchesThisCatalog() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let bundled = try JSONDecoder().decode([WovenMCPToolDefinition].self,
      from: Data(contentsOf: root.appending(path: "remote/src/woven-mcp-tools.json")))
    #expect(bundled.map(\.name) == WovenMCPCatalog.tools.map(\.name))
    for (linux, swift) in zip(bundled, WovenMCPCatalog.tools) { #expect(linux == swift, "\(swift.name) differs") }
  }

  /// Session management on another workspace: status pages with `before`, send
  /// steers, stop and respond are mutations, and every one may name a workspace.
  @Test func sessionManagementToolsNameWorkspaces() throws {
    let id = "22222222-2222-4222-8222-222222222222", workspace = "33333333-3333-4333-8333-333333333333"
    let status = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_sessions_status",
      arguments: .object(["id": .string(id), "workspace": .string(workspace), "before": .string("c1")])).arguments)
    #expect(status.action == "status" && status.options["workspace"] == workspace && status.options["before"] == "c1" && !status.isMutation)
    let respond = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_sessions_respond", arguments: .object([
      "id": .string(id), "interaction": .string("q1"), "answers": .object(["a": .array([.string("yes")])]), "cancelled": .bool(true)])).arguments)
    #expect(respond.isMutation && respond.options["interaction"] == "q1" && respond.options["cancelled"] == "true")
    #expect(try JSONDecoder().decode([String: [String]].self, from: Data(respond.required("answers").utf8)) == ["a": ["yes"]])
    let stop = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_sessions_stop", arguments: .object(["id": .string(id)])).arguments)
    #expect(stop.isMutation && stop.action == "stop")
    let list = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_sessions_list", arguments: .object(["workspace": .string(workspace)])).arguments)
    #expect(list.options["workspace"] == workspace)
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["sessions", "stop", "--id", id, "--text", "no"]) }
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
