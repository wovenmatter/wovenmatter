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

}
