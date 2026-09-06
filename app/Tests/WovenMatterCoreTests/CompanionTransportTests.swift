import Foundation
import XCTest
@testable import WovenMatterDashboardStore
import WovenMatterCore

final class CompanionTransportTests: XCTestCase {
  func testPairOncePersistAuthenticateRevokeAndRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("credentials.json")
    let auth = try CompanionAuthentication(fileURL: file)
    let endpoint = try XCTUnwrap(URL(string: "https://fixture.test.ts.net:8443/wovenmatter"))
    let offer = try await auth.createOffer(endpoint: endpoint)
    let deviceID = UUID().uuidString.lowercased()
    let request = CompanionPairRequest(token: offer.payload.token, deviceID: deviceID, deviceName: "Fixture iPhone")
    let response = try await auth.pair(request, workspaceID: "fixture-workspace")
    let device = try await auth.authenticate(bearer: response.credential)
    XCTAssertEqual(device.id, deviceID)
    do { _ = try await auth.pair(request, workspaceID: "fixture-workspace"); XCTFail("Pairing code was reused") }
    catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "invalid_pairing") }
    let disk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(disk.contains(response.credential))
    XCTAssertFalse(disk.contains(offer.payload.token))
    let reopened = try CompanionAuthentication(fileURL: file)
    let restored = try await reopened.authenticate(bearer: response.credential)
    XCTAssertEqual(restored.id, deviceID)
    try await reopened.revoke(deviceID: deviceID)
    let revoked = try CompanionAuthentication(fileURL: file)
    do { _ = try await revoked.authenticate(bearer: response.credential); XCTFail("Revoked credential was accepted") }
    catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "unauthorized") }
  }

  func testExpiredPairingAndVersionMismatchNeverCreateDevice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = FixtureClock()
    let auth = try CompanionAuthentication(fileURL: directory.appendingPathComponent("credentials.json"), now: { clock.now })
    let offer = try await auth.createOffer(endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter")!)
    clock.advance(301)
    let request = CompanionPairRequest(token: offer.payload.token, deviceID: UUID().uuidString, deviceName: "Fixture")
    do { _ = try await auth.pair(request, workspaceID: "fixture"); XCTFail("Expired offer accepted") }
    catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "invalid_pairing") }
    let mismatch = CompanionPairRequest(token: offer.payload.token, deviceID: UUID().uuidString, deviceName: "Fixture", protocolVersion: 2)
    do { _ = try await auth.pair(mismatch, workspaceID: "fixture"); XCTFail("Unknown protocol accepted") }
    catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "version_mismatch") }
    let devices = await auth.devices()
    XCTAssertTrue(devices.isEmpty)
  }

  func testHTTPReaderHandlesSplitUTF8AndRejectsSmugglingAndBrowserOrigins() throws {
    let body = Data("{\"title\":\"Idea 🌿\"}".utf8)
    var wire = Data("POST /v1/mutations HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    wire.append(body)
    var parser = CompanionHTTPParser()
    var request: CompanionHTTPRequest?
    for byte in wire { request = try parser.append(Data([byte])) }
    XCTAssertEqual(request?.body, body)
    for header in ["Content-Length: 0\r\nContent-Length: 5", "Transfer-Encoding: chunked", "Origin: https://hostile.example", "Upgrade: websocket"] {
      var invalid = CompanionHTTPParser()
      XCTAssertThrowsError(try invalid.append(Data("GET /v1/snapshot HTTP/1.1\r\nHost: localhost\r\n\(header)\r\n\r\n".utf8)))
    }
    var oversized = CompanionHTTPParser()
    XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: CompanionHTTPParser.maximumHeaderBytes + 1)))
  }

  func testActualLoopbackListenerAndRestart() async throws {
    let server = CompanionHTTPServer { request in
      .init(body: request.body.isEmpty ? Data("{\"live\":true}".utf8) : request.body)
    }
    let port = try await server.start()
    defer { server.stop() }
    let url = URL(string: "http://127.0.0.1:\(port)/v1/hello")!
    let (data, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"live\":true}")
    server.stop()
    let secondPort = try await server.start()
    let (_, secondResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(secondPort)/v1/hello")!)
    XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
  }

  func testProbeBoundsOutputTimeoutAndCancellation() async throws {
    do {
      _ = try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], maximumBytes: 1024, timeout: 1)
      XCTFail("Unbounded output was accepted")
    } catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "probe_too_large") }
    let start = Date()
    do {
      _ = try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
      XCTFail("Unresponsive child was accepted")
    } catch { XCTAssertEqual((error as? CompanionAPIError)?.code, "probe_timeout") }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let task = Task {
      try await CompanionProcessProbe().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 10)
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled probe succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  @MainActor func testStoppedServeProbeCannotLaunchAfterReplacementStarts() async throws {
    let probes = DelayedServeProbes()
    let child = FixtureServingProcess()
    let serve = CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
      probe: { _, args in await probes.response(args) },
      launch: { _, _ in child.launches += 1; child.isRunning = true; return child })
    let stale = Task { try await serve.start(loopbackPort: 50001) }
    await probes.waitForFirstProbe()
    serve.stop()
    let endpoint = try await serve.start(loopbackPort: 50002)
    XCTAssertEqual(endpoint.port, 8443)
    await probes.releaseFirst()
    do { _ = try await stale.value; XCTFail("Stopped attempt resumed") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(child.launches, 1)
    XCTAssertTrue(serve.isRunning)
    serve.stop()
    XCTAssertFalse(child.isRunning)
  }

  @MainActor func testServeInspectionIncludesAllForegroundAndPersistentPorts() throws {
    let data = Data(#"{"TCP":{"443":{"HTTPS":true}},"Foreground":{"existing":{"TCP":{"8443":{"HTTPS":true}},"Web":{}}}}"#.utf8)
    XCTAssertEqual(try CompanionTailscaleServe.occupiedPorts(in: data), Set([443, 8443]))
  }
}

private final class FixtureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_000)
  var now: Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

@MainActor private final class FixtureServingProcess: CompanionServingProcess {
  var isRunning = false
  var launches = 0
  func terminate() { isRunning = false }
}

private actor DelayedServeProbes {
  var first: CheckedContinuation<Void, Never>?
  var waiter: CheckedContinuation<Void, Never>?
  var statusCalls = 0
  var serveCalls = 0
  func response(_ arguments: [String]) async -> Data {
    if arguments.first == "status" {
      statusCalls += 1
      if statusCalls == 1 {
        await withCheckedContinuation { first = $0; waiter?.resume(); waiter = nil }
      }
      return Data(#"{"BackendState":"Running","Self":{"DNSName":"fixture.test.ts.net."}}"#.utf8)
    }
    serveCalls += 1
    if serveCalls == 1 { return Data("{}".utf8) }
    return Data(#"{"Foreground":{"ours":{"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:8443":{"Handlers":{"/wovenmatter":{"Proxy":"http://127.0.0.1:50002"}}}}}}}"#.utf8)
  }
  func waitForFirstProbe() async {
    if first != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func releaseFirst() { first?.resume(); first = nil }
}
