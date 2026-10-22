import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct WovenMatterToolProtocolTests {

  @Test func contextIsAReadWithoutCallerSelectedMessageOrNote() throws {
    let command = try WovenMatterToolCommand(["context"])
    #expect(command.action == "context" && !command.isMutation && !command.wantsHelp)
    #expect(WovenMatterToolCommand.help(for: try .init(["context", "--help"])) == WovenMatterToolCommand.contextHelp)
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["context", "--note-id", "other"]) }
  }


  @Test func helpIsLazyForEveryGroup() throws {
    #expect(try WovenMatterToolCommand([]).wantsHelp)
    for group in WorkspaceToolGroup.allCases {
      #expect(try WovenMatterToolCommand([group.rawValue, "help"]).group == group)
      #expect(WovenMatterToolCommand.help(for: group).contains("wovenmatter " + group.rawValue))
    }
  }

  @Test func actionSpecificOptionsContradictionsAndHelpAreExplicit() throws {
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
    let apply = try WovenMatterToolCommand(["notes", "apply", "--help"])
    #expect(WovenMatterToolCommand.help(for: apply).contains("Operations are a JSON array"))
    let table = try WovenMatterToolCommand(["notes", "table", "set-cell", "--help"])
    #expect(WovenMatterToolCommand.help(for: table).contains("--table-id"))
    #expect(try WovenMatterToolCommand(["notes", "table", "help"]).wantsHelp)
    let release = try WovenMatterToolCommand(["sessions", "release", "--help"])
    #expect(WovenMatterToolCommand.help(for: release).contains("--epoch"))
  }

  @Test func automationJSONAndScreenshotExportKeepAuthorityOnTheCaller() throws {
    let command = try WovenMatterToolCommand(["browser", "call", "--json", "--image", "--request-id", "fixture"])
    #expect(command.options["json"] == "--image")
    #expect(throws: (any Error).self) { try WovenMatterToolCommand(["computer", "call", "--json", "{}", "--session", "other"]) }
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let bytes = Data("synthetic screenshot".utf8)
    let response = WovenMatterToolResponse(result: .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(bytes.base64EncodedString())])])]))
    let exported = try WovenAutomationOutput.exportImage(response, to: file)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(exported.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["type"]?.stringValue == "text")
    #expect(throws: (any Error).self) { try WovenAutomationOutput.exportImage(response, to: file) }
  }

}

extension WovenMatterToolProtocolTests {
}
