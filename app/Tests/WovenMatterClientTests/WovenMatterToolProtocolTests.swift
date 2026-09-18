import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct WovenMatterToolProtocolTests {
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

  @Test func malformedCommandsAndAuthorityOverridesAreRejected() {
    for arguments in [["unknown"], ["sessions", "delete-everything"],
                      ["history", "search", "--caller", "another-session"],
                      ["sessions", "send", "--text"], ["sessions", "send", "--text", "a", "--text", "b"]] {
      #expect(throws: (any Error).self) { try WovenMatterToolCommand(arguments) }
    }
  }
}
