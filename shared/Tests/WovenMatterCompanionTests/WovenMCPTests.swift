import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Woven MCP contract")
struct WovenMCPTests {
  private let requestID = "11111111-1111-4111-8111-111111111111"

  @Test func focusedCatalogAndTypedMapping() throws {
    let definitions = WovenMCPCatalog.tools
    #expect(Set(definitions.map(\.name)).count == definitions.count)
    #expect(Set(definitions.compactMap(\.group)) == Set(WorkspaceToolGroup.allCases))
    for name in ["woven_browser_cancel", "woven_computer_cancel", "woven_executor_cancel"] {
      #expect(definitions.first(where: { $0.name == name })?.isMutation == true)
    }
    for definition in definitions {
      let properties = try #require(definition.inputSchema.objectValue?["properties"]?.objectValue)
      #expect(properties["arguments"] == nil)
      #expect(properties["file"] == nil)
      #expect(properties["callerID"] == nil)
      #expect(properties["contextID"] == nil)
      #expect(properties["requestID"] != nil)
      #expect(definition.inputSchema.objectValue?["additionalProperties"] == .bool(false))
    }
    let request = try WovenMCPCatalog.request(name: "woven_notes_table_set_cell", arguments: [
      "noteID": .string("note"), "tableID": .string("table"), "row": .number(2), "column": .number(3),
      "text": .string("--help\nquoted text"), "revision": .string("rev"), "requestID": .string(requestID)
    ], contextID: "native-capture")
    let command = try WovenMatterToolCommand(request.arguments)
    #expect(command.subaction == "set-cell")
    #expect(command.options["text"] == "--help\nquoted text")
    #expect(!command.wantsHelp)
    #expect(request.requestID == requestID)
    #expect(request.contextID == "native-capture")
  }

  @Test func everyCatalogFieldMapsToAnAcceptedInternalOperation() throws {
    func sample(_ schema: GatewayJSONValue) -> GatewayJSONValue {
      let spec = schema.objectValue ?? [:]
      if let first = spec["enum"]?.arrayValue?.first { return first }
      switch spec["type"]?.stringValue {
      case "integer", "number": return spec["minimum"] ?? .number(1)
      case "boolean": return .bool(true)
      case "array": return .array([])
      case "object": return .object([:])
      default: return .string("fixture")
      }
    }
    for definition in WovenMCPCatalog.tools {
      let schema = try #require(definition.inputSchema.objectValue)
      let properties = try #require(schema["properties"]?.objectValue)
      let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let base = Dictionary(uniqueKeysWithValues: required.map { ($0, sample(properties[$0]!)) })
      for (name, property) in properties {
        var arguments = base
        arguments[name] = name == "requestID" ? .string(requestID) : sample(property)
        let request = try WovenMCPCatalog.request(name: definition.name, arguments: arguments)
        let command = try WovenMatterToolCommand(request.arguments)
        #expect(command.group == definition.group || definition.name == "woven_context")
      }
    }
  }

  @Test func inputAuthorityAndSchemaValidation() throws {
    for extra in ["callerID", "contextID", "file", "arguments", "bearerToken"] {
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_goals_get", arguments: [extra: .string("forged")])
      }
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_notes_read", arguments: ["noteID": .string("n"), "characters": .number(65_537)])
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_notes_read", arguments: ["noteID": .number(1)])
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_goals_set", arguments: ["objective": .string("goal"), "requestID": .string("not-a-uuid")])
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_browser", arguments: ["action": .string("unknown")])
    }
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_goals_set", arguments: [:])
    }
  }

  @Test func structuredPayloadsAndBooleans() throws {
    let operations: GatewayJSONValue = .array([.object(["type": .string("appendText"), "text": .string("hello")])])
    let note = try WovenMCPCatalog.request(name: "woven_notes_apply", arguments: ["noteID": .string("n"), "operations": operations])
    let command = try WovenMatterToolCommand(note.arguments)
    #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.options["json"]!.utf8)) == operations)
    let session = try WovenMCPCatalog.request(name: "woven_sessions_notifications", arguments: ["id": .string("s"), "epoch": .string("epoch"), "enabled": .bool(false)])
    #expect(try WovenMatterToolCommand(session.arguments).options["enabled"] == "false")
    let calendar = try WovenMCPCatalog.request(name: "woven_calendar_create", arguments: ["title": .string("event"), "startsAt": .string("2026-10-26T12:00:00Z"), "allDay": .bool(false)])
    #expect(try WovenMatterToolCommand(calendar.arguments).options["all-day"] == nil)
  }

  @Test func automationPreservesImages() throws {
    let image: GatewayJSONValue = .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string("AA==")])
    let response = WovenMCPCatalog.result(.init(result: .object(["content": .array([image]), "details": .object(["frameId": .string("frame")])]), requestID: requestID))
    #expect(response.objectValue?["content"] == .array([image]))
    #expect(response.objectValue?["structuredContent"]?.objectValue?["requestID"] == .string(requestID))
    let request = try WovenMCPCatalog.request(name: "woven_computer", arguments: ["action": .string("click"), "frameId": .string("frame"), "x": .number(10), "y": .number(20), "requestID": .string(requestID)])
    let input = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(WovenMatterToolCommand(request.arguments).required("json").utf8))
    #expect(input.objectValue?["frameId"] == .string("frame"))
    #expect(input.objectValue?["requestID"] == nil)
  }

  @Test func htmlContractMapsPreparedPagesWithoutMakingPublicationReplayable() throws {
    let render = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_html_render" })
    let preview = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_html_preview" })
    #expect(render.inputSchema.objectValue?["properties"]?.objectValue?["html"]?.objectValue?["maxLength"] == .number(512_000))
    #expect(render.annotations.objectValue?["idempotentHint"] == .bool(false))
    #expect(preview.annotations.objectValue?["idempotentHint"] == .bool(true))
    let html = "<img src='data:image/png;base64," + String(repeating: "A", count: 600_000) + "'>"
    let request = try WovenMCPCatalog.request(name: render.name, arguments: ["html": .string(html), "title": .string("Chart"), "height": .number(160)])
    let command = try WovenMatterToolCommand(request.arguments)
    let page = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(command.required("json").utf8))
    #expect(command.group == .html)
    #expect(page.objectValue?["action"] == .string("render"))
    #expect(page.objectValue?["html"] == .string(html))
    let message: GatewayJSONValue = .object(["method": .string("tools/call"), "params": .object(["name": .string(render.name)])])
    #expect(WovenMCPServer.maximumRequestBytes(for: message) == 40 * 1024 * 1024)
    #expect(WovenMCPServer.maximumRequestBytes(for: .object(["method": .string("tools/list")])) == 4 * 1024 * 1024)
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: render.name, arguments: ["html": .string("<p>Chart</p>"), "title": .string("Chart"), "height": .number(160), "conversationID": .string("forged")])
    }
  }

  @Test func jsonRPCIdentityAndNotifications() async throws {
    let response = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .number(7), "method": .string("tools/call"),
      "params": .object(["name": .string("woven_goals_get"), "arguments": .object([:])])])) { request in
      #expect(UUID(uuidString: request.requestID) != nil)
      return .init(result: .string("goal"))
    }
    #expect(response?.objectValue?["id"] == .number(7))
    #expect(UUID(uuidString: response?.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["requestID"]?.stringValue ?? "") != nil)
    let notification = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "method": .string("tools/call"),
      "params": .object(["name": .string("woven_goals_set"), "arguments": .object(["objective": .string("never run")])])])) { _ in
      Issue.record("A notification must not execute tools")
      return .init()
    }
    #expect(notification == nil)
  }

  @Test func toolVisibilityAndAuthorizationPrecedeDispatch() async throws {
    let list = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list")]), allowedTools: ["woven_goals_get"]) { _ in .init() }
    #expect(list?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == 1)
    let denied = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("call"), "method": .string("tools/call"), "params": .object(["name": .string("woven_computer"), "arguments": .object(["action": .string("screenshot")])])]), allowedTools: ["woven_goals_get"]) { _ in
      Issue.record("A hidden tool must not dispatch")
      return .init()
    }
    #expect(denied?.objectValue?["error"]?.objectValue?["code"] == .number(-32602))
  }

  @Test func linuxCatalogMatchesCanonicalDefinitions() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appending(path: "remote/src/woven-mcp-tools.json")
    let bundled = try JSONDecoder().decode([WovenMCPToolDefinition].self, from: Data(contentsOf: url))
    #expect(bundled == WovenMCPCatalog.tools)
  }
}
