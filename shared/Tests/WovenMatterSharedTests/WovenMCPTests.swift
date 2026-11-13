import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Woven MCP contract")
struct WovenMCPTests {
  private let requestID = "11111111-1111-4111-8111-111111111111"

  @Test func pageToolsShareTheNotesGroupAndMapToItsCommands() throws {
    let expected = ["list", "create", "read", "update", "add_component", "update_component", "move_component", "remove_component", "link_session", "unlink_session"].map { "woven_pages_" + $0 }
    let tools = WovenMCPCatalog.tools.filter { $0.name.hasPrefix("woven_pages_") }
    #expect(Set(tools.map(\.name)) == Set(expected))
    #expect(tools.allSatisfy { $0.group == .notes })
    #expect(Set(tools.filter { !$0.isMutation }.map(\.name)) == ["woven_pages_list", "woven_pages_read"])
    #expect(!WovenMCPCatalog.tools.contains { $0.name.hasPrefix("woven_boards_") || $0.name == "woven_notes_canvas" })
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["boards", "list"]) }
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["pages", "edit-layout", "--note-id", "p", "--json", "[]"]) }
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["notes", "canvas", "--note-id", "n", "--json", "[]"]) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_notes_create", arguments: .object(["title": .string("B"), "kind": .string("canvas")])) }

    let request = try WovenMCPCatalog.request(name: "woven_pages_update_component", arguments: .object([
      "pageID": .string("p"), "componentID": .string("c"), "componentRevision": .string("r"), "status": .string("done"),
      "outcome": .string(""), "clearReview": .bool(true), "requestID": .string(requestID)]))
    let command = try WovenMatterToolCommand(request.arguments)
    #expect(command.group == .notes && command.action == "page-update-component" && command.isPageCommand && command.isMutation)
    #expect(command.options["note-id"] == "p" && command.options["id"] == "c" && command.options["component-revision"] == "r")
    #expect(command.options["outcome"] == "" && command.options["clear-review"] == "true")
    #expect(request.requestID == requestID)
    for action in ["list", "read"] {
      let read = try WovenMatterToolCommand(["pages", action] + (action == "read" ? ["--note-id", "p"] : []))
      #expect(read.group == .notes && !read.isMutation)
    }
    let moved = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_pages_move_component", arguments: .object([
      "pageID": .string("p"), "componentID": .string("c"), "parentID": .string("s"), "afterID": .string("a"), "atStart": .bool(false)])).arguments)
    #expect(moved.options["parent-id"] == "s" && moved.options["after-id"] == "a" && moved.options["at-start"] == nil)
    let removed = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_pages_remove_component", arguments: .object([
      "pageID": .string("p"), "componentID": .string("c"), "subtreeRevision": .string("r"), "removal": .string("removeSubtree")])).arguments)
    #expect(removed.options["subtree-revision"] == "r" && removed.options["removal"] == "removeSubtree")
    let block = try WovenMCPCatalog.request(name: "woven_pages_add_component", arguments: .object([
      "pageID": .string("p"), "kind": .string("section"), "block": .object(["type": .string("richText")])]))
    #expect(try WovenMatterToolCommand(block.arguments).options["json"]?.contains("richText") == true)
  }

  @Test func pageToolsAcceptNoProvenanceAndRequireTheirRevisions() throws {
    let base: [String: GatewayJSONValue] = ["pageID": .string("p"), "componentID": .string("c"), "componentRevision": .string("r")]
    for forged in ["updatedBy", "createdBy", "actor", "updatedAt", "createdAt", "caller", "conversationID"] {
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_pages_update_component", arguments: .object(base.merging([forged: .string("forged")]) { $1 }))
      }
      #expect(throws: WorkspaceToolError.self) {
        try WovenMCPCatalog.request(name: "woven_pages_add_component", arguments: .object(["pageID": .string("p"), forged: .string("forged")]))
      }
    }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_pages_update_component", arguments: .object(["pageID": .string("p"), "componentID": .string("c"), "status": .string("done")])) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_pages_update", arguments: .object(["pageID": .string("p"), "title": .string("T")])) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_pages_update_component", arguments: .object(base.merging(["status": .string("started")]) { $1 })) }
    #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_pages_remove_component", arguments: .object(["pageID": .string("p"), "componentID": .string("c"), "removal": .string("everything")])) }
  }

  @Test func artifactStateToolsStayInNotesAndCarryNoDocument() throws {
    let read = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_notes_artifact_state" })
    let write = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_notes_artifact_state_edit" })
    #expect(read.group == .notes && !read.isMutation)
    #expect(write.group == .notes && write.isMutation)
    let request = try WovenMCPCatalog.request(name: "woven_notes_artifact_state_edit", arguments: .object([
      "noteID": .string("n"), "edits": .array([.object(["action": .string("set"), "key": .string("app:x"), "value": .null, "expectedVersion": .number(2)])])]))
    let command = try WovenMatterToolCommand(request.arguments)
    #expect(command.isMutation)
    let edits = try JSONDecoder().decode([ArtifactStateEdit].self, from: Data(command.required("json").utf8))
    #expect(edits == [ArtifactStateEdit(action: .set, key: "app:x", value: .null, expectedVersion: 2)])
    #expect(throws: WorkspaceToolError.self) {
      try WovenMCPCatalog.request(name: "woven_notes_artifact_state_edit", arguments: .object(["noteID": .string("n"), "edits": .array([]), "html": .string("<p>")]))
    }
    #expect(!(try WovenMatterToolCommand(["notes", "artifact-state", "--note-id", "n"])).isMutation)
    #expect(RemoteNoteEditEnvelope.requiresRevision([.artifactState([ArtifactStateEdit(action: .remove, key: "app:x")])]) == false)
  }

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

  /// Waiting: a read-only session tool with a bounded timeout and three targets.
  @Test func sessionWaitIsBoundedAndReadOnly() throws {
    let id = "22222222-2222-4222-8222-222222222222", workspace = "33333333-3333-4333-8333-333333333333"
    let wait = try WovenMatterToolCommand(WovenMCPCatalog.request(name: "woven_sessions_wait", arguments: .object([
      "id": .string(id), "workspace": .string(workspace), "until": .string("either"), "timeoutSeconds": .number(50)])).arguments)
    #expect(wait.group == .sessions && wait.action == "wait" && !wait.isMutation)
    #expect(wait.options["until"] == "either" && wait.options["timeout-seconds"] == "50" && wait.options["workspace"] == workspace)
    let tool = try #require(WovenMCPCatalog.tools.first { $0.name == "woven_sessions_wait" })
    #expect(tool.group == .sessions && !tool.isMutation)
    #expect(tool.inputSchema.objectValue?["required"] == .array(["id", "timeoutSeconds", "until"].map(GatewayJSONValue.string)))
    for arguments: [String: GatewayJSONValue] in [["id": .string(id), "until": .string("done"), "timeoutSeconds": .number(5)],
                                                   ["id": .string(id), "until": .string("idle"), "timeoutSeconds": .number(Double(StreamProtocol.maximumWaitSeconds + 1))],
                                                   ["id": .string(id), "until": .string("idle"), "timeoutSeconds": .number(0)],
                                                   ["id": .string(id), "timeoutSeconds": .number(5)]] {
      #expect(throws: WorkspaceToolError.self) { try WovenMCPCatalog.request(name: "woven_sessions_wait", arguments: .object(arguments)) }
    }
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["sessions", "wait", "--id", id, "--until", "done"]) }
    #expect(throws: WorkspaceToolError.self) { try WovenMatterToolCommand(["sessions", "wait", "--id", id, "--timeout-seconds", "51"]) }
  }

  /// The Linux server builds the same wake-up text (remote/test/session-watch.test.mjs).
  @Test func wakeUpTextMatchesTheSharedFixtures() throws {
    struct Fixture: Decodable {
      let kind: SessionWakeUp.Kind, sessionID: String, title: String?, workspaceName: String, question: String?, last: Bool?, text: String
    }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "SessionWakeUpFixtures.json")
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    #expect(fixtures.count >= 5)
    for fixture in fixtures {
      #expect(SessionWakeUp.text(kind: fixture.kind, sessionID: fixture.sessionID, title: fixture.title, workspaceName: fixture.workspaceName,
                                 question: fixture.question, last: fixture.last ?? false) == fixture.text)
    }
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
