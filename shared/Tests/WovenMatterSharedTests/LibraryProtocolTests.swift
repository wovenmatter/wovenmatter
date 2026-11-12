import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Library wire compatibility")
struct LibraryProtocolTests {

  @Test("pairing and hello agree on the current format and reject older pairing codes")
  func versionNegotiation() throws {
    let endpoint = URL(string: "https://fixture.test.ts.net/wovenmatter")!
    let token = String(repeating: "a", count: 32)
    let payload = try PairingPayload(endpoint: endpoint, token: token)
    #expect(payload.protocolVersion == LibraryProtocol.version)
    #expect(try PairingPayload.parseURL(payload.encodedURL) == payload)
    #expect(PairRequest(token: token, deviceID: "phone", deviceName: "iPhone").protocolVersion == LibraryProtocol.version)
    #expect(PairResponse(workspaceID: "workspace", deviceID: "phone", credential: token).protocolVersion == LibraryProtocol.version)
    #expect(LibraryHello(workspaceID: "workspace", hostName: "Mac", capabilities: []).protocolVersion == LibraryProtocol.version)
    #expect(throws: LibraryAPIError.self) {
      try PairingPayload(endpoint: endpoint, token: token, protocolVersion: 1)
    }
  }

  @Test("session choices, attachments and context encode as the Linux execution server reads them")
  func memberCommandFields() throws {
    let digest = String(repeating: "a", count: 64)
    let command = LibraryCommand(commandID: "c", deviceID: "d", kind: .send, conversationID: "x", text: "Hello", noteID: "note",
      sessionOptions: LibrarySessionOptions(workingDirectory: "/srv/project", model: "m", thinking: "high", permission: "auto", enabledTools: ["notes"]),
      attachments: [LibraryAttachmentReference(id: digest, name: "a.png", mimeType: "image/png", byteCount: 3)], promptContext: "Visible")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any]
    let options = encoded?["sessionOptions"] as? [String: Any]
    #expect(options?["workingDirectory"] as? String == "/srv/project")
    #expect(options?["enabledTools"] as? [String] == ["notes"])
    let attachment = (encoded?["attachments"] as? [[String: Any]])?.first
    #expect(attachment?["id"] as? String == digest)
    #expect(attachment?["mimeType"] as? String == "image/png")
    #expect(encoded?["promptContext"] as? String == "Visible")
    #expect(try JSONDecoder().decode(LibraryCommand.self, from: JSONEncoder().encode(command)) == command)
    // What the server writes back: a coded rejection, described options and listed files.
    let receipt = try JSONDecoder().decode(LibraryCommandReceipt.self, from: Data(#"{"commandID":"c","deviceID":"d","status":"rejected","message":"Locked","code":"default_agent_locked"}"#.utf8))
    #expect(receipt.code == "default_agent_locked")
    let option = try JSONDecoder().decode(SessionSettingOption.self, from: Data(#"{"id":"auto","label":"Auto","description":"Classifier"}"#.utf8))
    #expect(option.description == "Classifier")
    let message = try JSONDecoder().decode(LibraryMessage.self, from: Data(#"{"id":"m","conversationID":"x","role":"user","content":"","createdAt":"","attachments":[{"id":"\#(digest)","name":"a.png","mimeType":"image/png","byteCount":3}]}"#.utf8))
    #expect(message.attachments?.first?.byteCount == 3)
  }

}
