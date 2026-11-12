import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct OpenCodeWireCaptureTests {

  @Test func globalStreamCapturesOnlyTheSelectedSessionAndUsesEnvelopeIdentities() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CaptureFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let capture = OpenCodeWireCapture()
    let client = OpenCodeHTTPClient(connection: try OpenCodeConnection(identity: "scope-test", url: URL(string: "http://fixture.invalid")!, password: "credential"), session: session)
      .recording { capture.append($0, $1) }
    try await client.events("/api/event", accept: { $0["data"]["sessionID"].text == "ses_fixture" }) { value in
      #expect(value["data"]["sessionID"].text == "ses_fixture")
    }
    let native = try capture.values.filter { $0.0 == "native" }.flatMap { try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: $0.1).records }
    #expect(native.map(\.id) == ["event:live-1", "event:live-2"])
    #expect(!capture.values.contains { String(decoding: $0.1, as: UTF8.self).contains("foreign-private") })
  }

  @Test func preservesUnknownHTTPAndSSEFieldsWithoutCredentials() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CaptureFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let capture = OpenCodeWireCapture()
    let connection = try OpenCodeConnection(identity: "wire-test", url: URL(string: "http://fixture.invalid")!, password: "credential-do-not-retain")
    let client = OpenCodeHTTPClient(connection: connection, session: session).recording { capture.append($0, $1) }
    _ = try await client.call("POST", "/api/session/ses_fixture/prompt", body: ["text": "hello"])
    try await client.events("/api/experimental/session/ses_fixture/log") { value in
      #expect(value["future_payload"]["unknown"].text == "preserved")
    }
    await #expect(throws: OpenCodeError.http(422)) { try await client.call("GET", "/api/failure") }
    let entries = try capture.values.filter { $0.0 != "native" }.map { (direction: $0.0, frame: try JSONDecoder().decode(WorkspaceHTTPObservation.self, from: $0.1)) }
    #expect(entries.contains { $0.direction == "out" && $0.frame.body.contains("hello") })
    #expect(entries.contains { $0.direction == "in" && $0.frame.body.contains("future_response") })
    #expect(entries.contains { $0.frame.status == 422 && $0.frame.body.contains("fixture rejection") })
    let rawStream = entries.filter { $0.direction == "in" && $0.frame.path.hasSuffix("/log") }.map(\.frame.body).joined()
    #expect(rawStream == CaptureFixtureProtocol.stream)
    #expect(!entries.contains { $0.frame.body.contains("credential-do-not-retain") })
    #expect(!capture.values.contains { String(decoding: $0.1, as: UTF8.self).contains("Authorization") })
    let native = try capture.values.filter { $0.0 == "native" }.map { try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: $0.1) }
    #expect(native.contains { $0.nativeSessionID == "ses_fixture" && $0.records.contains { $0.id == "event:native-1" && $0.payload.contains("future_payload") } })
  }

  @Test func readJournalRecordsARepeatedReadOnlyWhenItsAnswerChanges() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let connection = try OpenCodeConnection(identity: "read-test", url: URL(string: "http://reads.invalid")!, password: "credential")
    let capture = OpenCodeWireCapture()
    let client = OpenCodeHTTPClient(connection: connection, session: session).recording({ capture.append($0, $1) }, readJournal: OpenCodeReadJournal())
    func frames() throws -> [(direction: String, frame: WorkspaceHTTPObservation)] {
      try capture.values.filter { $0.0 != "native" }.map { ($0.0, try JSONDecoder().decode(WorkspaceHTTPObservation.self, from: $0.1)) }
    }
    ReadFixtureProtocol.answer.set("{\"data\":{\"id\":\"ses_read\",\"title\":\"One\"}}")
    for _ in 0..<3 { _ = try await client.call("GET", "/api/session/ses_read") }
    #expect(try frames().map(\.direction) == ["out", "in"])
    #expect(capture.values.filter { $0.0 == "native" }.count == 1)
    // Another query is another read.
    _ = try await client.call("GET", "/api/session/ses_read", query: ["limit": "1"])
    #expect(try frames().count == 4)
    ReadFixtureProtocol.answer.set("{\"data\":{\"id\":\"ses_read\",\"title\":\"Two\"}}")
    _ = try await client.call("GET", "/api/session/ses_read")
    // The same value with its keys in another order is unchanged.
    ReadFixtureProtocol.answer.set("{\"data\":{\"title\":\"Two\",\"id\":\"ses_read\"}}")
    _ = try await client.call("GET", "/api/session/ses_read")
    #expect(try frames().count == 6)
    #expect(try frames().last?.frame.body.contains("Two") == true)
    #expect(capture.values.filter { $0.0 == "native" }.count == 3)
    // Writes are always recorded, before they are sent.
    _ = try await client.call("POST", "/api/session/ses_read/prompt", body: ["text": "hello"])
    _ = try await client.call("POST", "/api/session/ses_read/prompt", body: ["text": "hello"])
    #expect(try frames().count == 10)

    // Without a journal every read is recorded.
    let unjournaled = OpenCodeWireCapture()
    let plain = OpenCodeHTTPClient(connection: connection, session: session).recording { unjournaled.append($0, $1) }
    for _ in 0..<2 { _ = try await plain.call("GET", "/api/session/ses_read") }
    #expect(unjournaled.values.filter { $0.0 != "native" }.count == 4)
  }
}

private final class ReadFixtureAnswer: @unchecked Sendable {
  private let lock = NSLock()
  private var value = "{}"
  func set(_ value: String) { lock.withLock { self.value = value } }
  func get() -> String { lock.withLock { value } }
}

private final class ReadFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let answer = ReadFixtureAnswer()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "reads.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(Self.answer.get().utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

private final class OpenCodeWireCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [(String, Data)] = []
  var values: [(String, Data)] { lock.withLock { entries } }
  func append(_ direction: String, _ data: Data) { lock.withLock { entries.append((direction, data)) } }
}

private final class CaptureFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let stream = "id: native-1\r\nevent: update\r\ndata: {\"future_payload\":{\"unknown\":\"preserved\"}}\r\n\r\n"
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let live = request.url!.path == "/api/event"
    let stream = live || request.url!.path.hasSuffix("/log")
    let failure = request.url!.path.hasSuffix("/failure")
    let response = HTTPURLResponse(url: request.url!, statusCode: failure ? 422 : 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": stream ? "text/event-stream" : "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let liveStream = ["{\"id\":\"live-1\",\"data\":{\"sessionID\":\"ses_fixture\"}}", "{\"id\":\"foreign-private\",\"data\":{\"sessionID\":\"foreign\"}}", "{\"id\":\"live-2\",\"data\":{\"sessionID\":\"ses_fixture\"}}"].map { "data: " + $0 + "\n\n" }.joined()
    client?.urlProtocol(self, didLoad: Data((live ? liveStream : stream ? Self.stream : failure ? "{\"error\":\"fixture rejection\"}" : "{\"future_response\":true}").utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}
