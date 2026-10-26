import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct WovenMatterToolProtocolTests {

  @Test func contextIsAReadWithoutCallerSelectedMessageOrNote() throws {
    let command = try WovenMatterToolCommand(["context"])
    #expect(command.action == "context" && !command.isMutation && !command.wantsHelp)
    let context = try #require(WovenMCPCatalog.tools.first(where: { $0.name == "woven_context" }))
    #expect(context.description.contains("consumed user message"))
    #expect(context.inputSchema.objectValue?["properties"]?.objectValue?["contextID"] == nil)
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["context", "--note-id", "other"]) }
  }



  @Test func typedDiscoveryCoversEveryGroupWithoutCLIAliases() throws {
    #expect(throws: (any Error).self) { try WovenMatterToolCommand([]) }
    for group in WorkspaceToolGroup.allCases {
      #expect(WovenMCPCatalog.tools.contains(where: { $0.group == group }))
      #expect(throws: (any Error).self) { try WovenMatterToolCommand([group.rawValue, "help"]) }
    }
  }

  @Test func actionSpecificOptionsContradictionsAndSchemasAreExplicit() throws {
    for arguments in [
      ["history", "runs", "--since", "2026-01-01T00:00:00Z"],
      ["history", "conversation", "session", "--kind", "wire.in"],
      ["sessions", "list", "--harness", "codex"],
      ["sessions", "send", "first", "--id", "second", "--text", "ambiguous"],
      ["notes", "apply", "--note-id", "note", "--json", "[]", "--file", "/tmp/edit.json"],
      ["calendar", "create", "--title", "Conflict", "--starts-at", "2026-01-01T00:00:00Z", "--all-day", "--timed"],
      ["calendar", "create", "--title", "Conflict", "--starts-at", "2026-01-01T00:00:00Z", "--no-repeat", "--repeat-unit", "day"],
      ["calendar", "update", "event", "--regular-event", "--model", "ignored"]
    ] {
      #expect(throws: (any Error).self) { try WovenMatterToolCommand(arguments) }
    }
    let apply = try #require(WovenMCPCatalog.tools.first(where: { $0.name == "woven_notes_apply" }))
    #expect(apply.inputSchema.objectValue?["properties"]?.objectValue?["operations"]?.objectValue?["type"] == .string("array"))
    let table = try #require(WovenMCPCatalog.tools.first(where: { $0.name == "woven_notes_table_set_cell" }))
    #expect(table.inputSchema.objectValue?["properties"]?.objectValue?["tableID"] != nil)
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["notes", "table", "help"]) }
    let release = try #require(WovenMCPCatalog.tools.first(where: { $0.name == "woven_sessions_release" }))
    #expect(release.inputSchema.objectValue?["properties"]?.objectValue?["epoch"]?.objectValue?["type"] == .string("string"))
  }

  @Test func automationJSONAndInlineImagesKeepAuthorityOnTheCaller() throws {
    let command = try WovenMatterToolCommand(["browser", "call", "--json", "--image", "--request-id", "fixture"])
    #expect(command.options["json"] == "--image")
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["computer", "call", "--json", "{}", "--session", "other"]) }
    let bytes = Data("synthetic screenshot".utf8)
    let response = WovenMatterToolResponse(result: .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(bytes.base64EncodedString())])])]))
    let content = try #require(WovenMCPCatalog.result(response).objectValue?["content"]?.arrayValue?.first?.objectValue)
    #expect(content["type"] == .string("image"))
    #expect(content["data"] == .string(bytes.base64EncodedString()))
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["browser", "call", "--json", "{}", "--image", "/tmp/output.png"]) }
  }

}

extension WovenMatterToolProtocolTests {
  @Test func agentsCannotOverrideChildPermissionOrTools() {
    for arguments in [["sessions", "create", "--tools", "[]"],
                      ["sessions", "create", "--tools", #"["sessions","calendar"]"#],
                      ["sessions", "create", "--permission", "unrestricted"]] {
      #expect(throws: (any Error).self) { try WovenMatterToolCommand(arguments) }
    }
  }
}
