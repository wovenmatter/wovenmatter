import Foundation
import XCTest
import WorkspaceFixtures
@testable import WovenMatterLibraryStore
import WovenMatterCore

final class LibraryTransportTests: XCTestCase {
  func testPairOncePersistAuthenticateRevokeAndRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("credentials.json")
    let auth = try DeviceAuthentication(fileURL: file)
    let endpoint = try XCTUnwrap(URL(string: "https://fixture.test.ts.net:8443/wovenmatter"))
    let offer = try await auth.createOffer(endpoint: endpoint)
    let deviceID = UUID().uuidString.lowercased()
    let request = PairRequest(token: offer.payload.token, deviceID: deviceID, deviceName: "Fixture iPhone")
    let response = try await auth.pairConfirmed(request, workspaceID: "fixture-workspace")
    let device = try await auth.authenticate(bearer: response.credential)
    XCTAssertEqual(device.id, deviceID)
    do { _ = try await auth.pairConfirmed(request, workspaceID: "fixture-workspace"); XCTFail("Pairing code was reused") }
    catch { XCTAssertEqual((error as? LibraryAPIError)?.code, "invalid_pairing") }
    let disk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(disk.contains(response.credential))
    XCTAssertFalse(disk.contains(offer.payload.token))
    let reopened = try DeviceAuthentication(fileURL: file)
    let restored = try await reopened.authenticate(bearer: response.credential)
    XCTAssertEqual(restored.id, deviceID)
    try await reopened.revoke(deviceID: deviceID)
    let revoked = try DeviceAuthentication(fileURL: file)
    do { _ = try await revoked.authenticate(bearer: response.credential); XCTFail("Revoked credential was accepted") }
    catch { XCTAssertEqual((error as? LibraryAPIError)?.code, "unauthorized") }

    // A store a newer Woven Matter wrote is refused and left as it is.
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    for (field, value) in [("admissionVersion", 4), ("version", 2)] {
      var newer = saved; newer[field] = value
      let data = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
      try data.write(to: file)
      XCTAssertThrowsError(try DeviceAuthentication(fileURL: file)) { XCTAssertEqual(($0 as? LibraryAPIError)?.code, "credential_store") }
      XCTAssertEqual(try Data(contentsOf: file), data)
    }
  }

  func testHTTPReaderHandlesSplitUTF8AndRejectsSmugglingAndBrowserOrigins() async throws {
    let body = Data("{\"title\":\"Idea 🌿\"}".utf8)
    var wire = Data("POST /v1/mutations HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    wire.append(body)
    var parser = LibraryHTTPParser()
    var request: LibraryHTTPRequest?
    for byte in wire { request = try parser.append(Data([byte])) }
    XCTAssertEqual(request?.body, body)
    for header in ["Content-Length: 0\r\nContent-Length: 5", "Transfer-Encoding: chunked", "Origin: https://hostile.example", "Upgrade: websocket"] {
      var invalid = LibraryHTTPParser()
      XCTAssertThrowsError(try invalid.append(Data("GET /v1/snapshot HTTP/1.1\r\nHost: localhost\r\n\(header)\r\n\r\n".utf8)))
    }
    var oversized = LibraryHTTPParser()
    XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: LibraryHTTPParser.maximumHeaderBytes + 1)))
  }

}
