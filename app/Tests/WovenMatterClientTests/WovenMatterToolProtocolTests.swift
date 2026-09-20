import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct WovenMatterToolProtocolTests {
  @Test func unsuccessfulNoteResponseRemainsAnUnsuccessfulCLIResponse() throws {
    let response = try WovenMatterToolResponse.note(.init(success: false, noteID: "note", error: "Revision conflict"))
    #expect(!response.success && response.error == "Revision conflict")
    #expect(response.result?.objectValue?["success"]?.boolValue == false)
    let replay = try WovenMatterToolResponse.note(.init(success: true, noteID: "note", revision: "original", replayed: true))
    #expect(replay.success && replay.result?.objectValue?["replayed"]?.boolValue == true)
  }

  @Test func helpIsLazyForEveryGroup() throws {
    #expect(try WovenMatterToolCommand([]).wantsHelp)
    for group in WorkspaceToolGroup.allCases {
      #expect(try WovenMatterToolCommand([group.rawValue, "help"]).group == group)
      #expect(WovenMatterToolCommand.help(for: group).contains("wovenmatter " + group.rawValue))
    }
  }

  @Test func noteJSONAndCreationFlagsKeepTheirExactValues() throws {
    let json = #"[{"type":"appendText","text":"literal --source-id"}]"#
    let note = try WovenMatterToolCommand(["notes", "apply", "--note-id", "n", "--json", json])
    #expect(note.options["json"] == json)
    let session = try WovenMatterToolCommand(["sessions", "create", "--title", "A title", "--text", "Line one\nLine two", "--independent"])
    #expect(session.options["text"] == "Line one\nLine two")
    #expect(session.options["independent"] == "true")
  }

  @Test func retryIDsAndLiteralFlagValuesDoNotChangeTheOperation() throws {
    let id = UUID().uuidString
    let arguments = ["sessions", "create", "--title", "--request-id", "--text", "--file", "--purpose", "--help"]
    let original = WovenMatterToolRequest(arguments: arguments, requestID: id)
    let retry = WovenMatterToolRequest(arguments: arguments + ["--request-id", id], requestID: id)
    #expect(original.operationArguments == retry.operationArguments)
    let command = try WovenMatterToolCommand(retry.arguments)
    #expect(!command.wantsHelp)
    #expect(command.optionIndices["file"] == nil)
    #expect(command.options["title"] == "--request-id")
    #expect(command.options["purpose"] == "--help")
    #expect(command.options["request-id"] == id)
    #expect(try WovenMatterToolCommand(["sessions", "send", "--help"]).wantsHelp)
    #expect(try WovenMatterToolCommand(["sessions", "receipts", "--before", id]).options["before"] == id)
    let response = WovenMatterToolResponse(requestID: id)
    #expect(try JSONDecoder().decode(WovenMatterToolResponse.self, from: JSONEncoder().encode(response)).requestID == id)
  }

  @Test func malformedCommandsAndAuthorityOverridesAreRejected() {
    for arguments in [["unknown"], ["sessions", "delete-everything"],
                      ["history", "search", "--caller", "another-session"],
                      ["sessions", "send", "--text"], ["sessions", "send", "--text", "a", "--text", "b"]] {
      #expect(throws: (any Error).self) { try WovenMatterToolCommand(arguments) }
    }
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
