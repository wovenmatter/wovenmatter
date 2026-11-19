import CryptoKit
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
  }

  /// The store as the released build wrote it, with the two keys that build
  /// kept at the top (`version`, `admissionVersion`): every grant, role, pin,
  /// roster record and unpair event loads as it is, the file is not rewritten
  /// by opening it, and the next save leaves those keys out.
  func testAStoreAnEarlierBuildWroteLoadsWithEveryGrantRoleAndPin() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(DeviceAuthentication.fileName)
    let own = "00000000-0000-4000-8000-000000000001", mac = "00000000-0000-4000-8000-000000000002"
    let phone = "00000000-0000-4000-8000-000000000003", gone = "00000000-0000-4000-8000-000000000004"
    let waiting = "00000000-0000-4000-8000-000000000005", event = "00000000-0000-4000-8000-000000000006"
    let ownLibrary = "00000000-0000-4000-8000-00000000000a", macLibrary = "00000000-0000-4000-8000-00000000000b"
    let phoneBearer = String(repeating: "p", count: 43), macBearer = String(repeating: "m", count: 43)
    func digest(_ value: String) -> String { Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString() }
    let key = Data(repeating: 7, count: 32).base64EncodedString(), signature = Data(repeating: 9, count: 64).base64EncodedString()
    let stored = Data("""
      {"version":1,"admissionVersion":3,
       "devices":[
        {"id":"\(phone)","name":"Fixture iPhone","pairedAt":800000000,"lastSeenAt":800000100,
         "metadata":{"kind":"iPhone","osVersion":"26.1","appVersion":"0.4.6"},
         "credentialHash":"\(digest(phoneBearer))","role":"client","acknowledged":[],"origin":"pairing"},
        {"id":"\(mac)","name":"Fixture Mac","pairedAt":800000000,"metadata":{"kind":"mac"},
         "credentialHash":"\(digest(macBearer))","role":"peer","acknowledged":[],
         "transcript":"\(Data(repeating: 3, count: 32).base64EncodedString())","origin":"join"}],
       "pins":{"\(mac)":{"libraryID":"\(macLibrary)","publicKey":"\(key)"}},
       "roster":{
        "\(mac)":{"name":"Fixture Mac","kind":"mac","introducedBy":"\(own)","admissions":[
          {"issuerDeviceID":"\(own)","issuerLibraryID":"\(ownLibrary)","subjectDeviceID":"\(mac)","subjectLibraryID":"\(macLibrary)",
           "subjectPublicKey":"\(key)","acknowledgedRevocations":[],"subjectSignature":"\(signature)","issuerSignature":"\(signature)"}]},
        "\(phone)":{"name":"Fixture iPhone","kind":"iPhone","introducedBy":"\(own)","admissions":[]}},
       "revocations":[{"eventID":"\(event)","deviceID":"\(gone)","revokerDeviceID":"\(own)","signature":"\(signature)"}],
       "pendingQRPairings":[
        {"device":{"id":"\(waiting)","name":"Waiting Mac","pairedAt":800000000,"lastSeenAt":800000000,"metadata":{"kind":"mac"},
                   "credentialHash":"\(digest("waiting"))"},
         "workspaceID":"fixture-workspace","expiresAt":800000300,"offerProof":"\(digest("offer"))",
         "encryptedCredential":"\(Data(repeating: 5, count: 60).base64EncodedString())","purpose":"library.peers.v2"}]}
      """.utf8)
    try stored.write(to: file)

    let auth = try DeviceAuthentication(fileURL: file)
    XCTAssertEqual(try Data(contentsOf: file), stored, "Opening the store must not rewrite it")
    let devices = await auth.devices()
    XCTAssertEqual(devices.map(\.id), [phone, mac])
    let pin = await auth.pin(for: mac)
    XCTAssertEqual(pin, PeerPin(libraryID: macLibrary, publicKey: Data(repeating: 7, count: 32)))
    let context = await auth.revocationContext(for: gone)
    XCTAssertEqual(context, [event])
    // The Mac's grant is still a peer grant for an admitted, pinned Mac; the
    // phone's still authenticates and is still only a client.
    let peer = try await auth.authenticate(bearer: macBearer)
    let admitted = await auth.isAuthorizedPeer(peer)
    XCTAssertTrue(admitted)
    let client = try await auth.authenticate(bearer: phoneBearer)
    XCTAssertEqual(client.id, phone)
    let asPeer = await auth.isAuthorizedPeer(client)
    XCTAssertFalse(asPeer)
    let membership = await auth.peerMembership()
    XCTAssertEqual(membership.entries.map(\.deviceID), [mac, phone])
    XCTAssertEqual(membership.entries.first?.admission?.subjectLibraryID, macLibrary)
    XCTAssertEqual(membership.revocations.map(\.eventID), [event])

    // Authenticating saved the last-seen times: the same store, without the two keys.
    let before = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    XCTAssertEqual(Set(saved.keys), Set(before.keys).subtracting(["version", "admissionVersion"]))
    for kept in ["pins", "roster", "revocations", "pendingQRPairings"] {
      XCTAssertEqual(saved[kept] as? NSObject, before[kept] as? NSObject, kept)
    }
    let reopened = try DeviceAuthentication(fileURL: file)
    let again = try await reopened.authenticate(bearer: macBearer)
    let stillAdmitted = await reopened.isAuthorizedPeer(again)
    XCTAssertTrue(stillAdmitted)
  }

  /// A grant from before grants carried a role takes one from what it is: a
  /// Mac may complete one signed join, anything else is a client.
  func testAGrantWithoutARoleTakesOneFromItsKind() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(DeviceAuthentication.fileName)
    let own = "00000000-0000-4000-8000-000000000001", mac = "00000000-0000-4000-8000-000000000002"
    let phone = "00000000-0000-4000-8000-000000000003"
    func digest(_ value: String) -> String { Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString() }
    try Data("""
      {"devices":[
        {"id":"\(phone)","name":"Fixture iPhone","pairedAt":800000000,"metadata":{"kind":"iPhone"},"credentialHash":"\(digest("phone"))"},
        {"id":"\(mac)","name":"Fixture Mac","pairedAt":800000000,"metadata":{"kind":"mac"},"credentialHash":"\(digest("mac"))"}]}
      """.utf8).write(to: file)
    let auth = try DeviceAuthentication(fileURL: file)
    await auth.useIdentity(.init(deviceID: own, libraryID: "00000000-0000-4000-8000-00000000000a", key: .init()))
    // Membership lists this Mac's client grants; a Mac waiting to join is not one.
    let membership = await auth.peerMembership()
    XCTAssertEqual(membership.entries.map(\.deviceID), [phone])
    let devices = await auth.devices()
    XCTAssertEqual(devices.map(\.id), [phone, mac])
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
