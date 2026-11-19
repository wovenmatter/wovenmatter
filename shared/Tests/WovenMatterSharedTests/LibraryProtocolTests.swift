import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Library wire contracts")
struct LibraryProtocolTests {

  @Test("a pairing code is its endpoint and token, and pairing messages carry no format number")
  func pairingCarriesNoFormatNumber() throws {
    let endpoint = URL(string: "https://fixture.test.ts.net/wovenmatter")!
    let token = String(repeating: "a", count: 32)
    let payload = try PairingPayload(endpoint: endpoint, token: token)
    let items = URLComponents(url: payload.encodedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.map(\.name) == ["endpoint", "token"])
    #expect(try PairingPayload.parseURL(payload.encodedURL) == payload)
    #expect(throws: LibraryAPIError.self) { try PairingPayload(endpoint: endpoint, token: "short") }
    func keys<Value: Encodable>(_ value: Value) throws -> Set<String> {
      Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]).keys)
    }
    let identity = PairingDeviceIdentity(deviceID: "mac", deviceName: "Mac", metadata: DeviceMetadata(kind: .mac))
    #expect(try keys(PairRequest(token: token, deviceID: "phone", deviceName: "iPhone")) == ["token", "deviceID", "deviceName"])
    #expect(try keys(PairResponse(workspaceID: "workspace", deviceID: "phone", credential: token, hostDeviceID: "mac")) == ["workspaceID", "deviceID", "credential", "hostDeviceID"])
    #expect(try keys(LibraryHello(workspaceID: "workspace", hostName: "Mac")) == ["workspaceID", "hostName"])
    #expect(try keys(DiscoveryAdvertisement(identity: identity)) == ["identity"])
    #expect(try keys(PairingApprovalRequest(requestID: "r", requestSecret: "s", identity: identity)) == ["requestID", "requestSecret", "identity"])
    #expect(try keys(LibraryIdentity(libraryID: "l", hostDeviceID: "mac")) == ["libraryID", "hostDeviceID"])
    #expect(try keys(WovenMatterToolRequest(arguments: ["notes", "list"], requestID: "r")) == ["requestID", "arguments"])
    #expect(try keys(StreamHello(deviceID: "d", libraryID: "l", workspaceID: "w", serverTime: 1))
      == ["deviceID", "libraryID", "workspaceID", "serverTime", "capabilities", "maxFrameBytes"])
  }

  @Test("capabilities and the peer pairing purpose are plain names")
  func capabilityNames() {
    #expect(StreamProtocol.capability == "stream")
    #expect(PairingPurpose.peerMac == "library.peers")
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

  @Test("a folder creation crosses the wire whole, and an action a build does not know fails to decode")
  func createFolderAction() throws {
    let id = UUID().uuidString.lowercased()
    let command = LibraryCommand(commandID: id, deviceID: "d", kind: .workspace,
      workspaceAction: .createFolder(id: id, name: "Field notes"), libraryID: "l", workspaceID: "w")
    let data = try JSONEncoder().encode(command)
    #expect(try JSONDecoder().decode(LibraryCommand.self, from: data) == command)
    let action = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["workspaceAction"] as? [String: [String: String]]
    #expect(action == ["createFolder": ["id": id, "name": "Field notes"]])
    #expect(command.conversationID == nil)
    #expect(!LibraryWorkspaceAction.createFolder(id: id, name: "Field notes").qualifiesForAnalytics)
    // A Mac from before the action reads it as this build reads a later one:
    // the whole command is refused, so only a Mac that lists the capability is sent it.
    let later = Data(#"{"commandID":"c","deviceID":"d","kind":"workspace","workspaceAction":{"aLaterAction":{"id":"w"}}}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(LibraryCommand.self, from: later) }
  }

}
