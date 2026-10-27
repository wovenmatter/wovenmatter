import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Woven MCP contract")
struct WovenMCPTests {
  private let requestID = "11111111-1111-4111-8111-111111111111"

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

  @Test func toolVisibilityAndAuthorizationPrecedeDispatch() async throws {
    let list = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("list"), "method": .string("tools/list")]), allowedTools: ["woven_goals_get"]) { _ in .init() }
    #expect(list?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == 1)
    let denied = await WovenMCPServer.handle(.object(["jsonrpc": .string("2.0"), "id": .string("call"), "method": .string("tools/call"), "params": .object(["name": .string("woven_computer"), "arguments": .object(["action": .string("screenshot")])])]), allowedTools: ["woven_goals_get"]) { _ in
      Issue.record("A hidden tool must not dispatch")
      return .init()
    }
    #expect(denied?.objectValue?["error"]?.objectValue?["code"] == .number(-32602))
  }

  @Test func browserProfileIsValidatedAndForwarded() throws {
    let request = try WovenMCPCatalog.request(name: "woven_browser", arguments: ["action": .string("tabs"), "profile": .string("work-2")])
    #expect(request.arguments.contains(where: { $0.contains("work-2") }))
    for profile in ["../escape", "", "MixedCase", String(repeating: "a", count: 33)] {
      #expect(throws: (any Error).self) {
        try WovenMCPCatalog.request(name: "woven_browser", arguments: ["action": .string("tabs"), "profile": .string(profile)])
      }
    }
  }
}
