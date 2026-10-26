import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Companion wire compatibility")
struct CompanionProtocolTests {

  @Test("pairing and hello agree on the current format and reject older pairing codes")
  func versionNegotiation() throws {
    let endpoint = URL(string: "https://fixture.test.ts.net/wovenmatter")!
    let token = String(repeating: "a", count: 32)
    let payload = try CompanionPairingPayload(endpoint: endpoint, token: token)
    #expect(payload.protocolVersion == CompanionProtocol.version)
    #expect(try CompanionPairingPayload.parseURL(payload.encodedURL) == payload)
    #expect(CompanionPairRequest(token: token, deviceID: "phone", deviceName: "iPhone").protocolVersion == CompanionProtocol.version)
    #expect(CompanionPairResponse(workspaceID: "workspace", deviceID: "phone", credential: token).protocolVersion == CompanionProtocol.version)
    #expect(CompanionHello(workspaceID: "workspace", hostName: "Mac", capabilities: []).protocolVersion == CompanionProtocol.version)
    #expect(throws: CompanionAPIError.self) {
      try CompanionPairingPayload(endpoint: endpoint, token: token, protocolVersion: 1)
    }
  }

}
