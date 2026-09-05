import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

struct PiRPCSettlementTests {
  @Test func acknowledgedPromptThenEOFThrows() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await fixture.serve(settles: false) }
    try await fixture.initialize()
    do {
      _ = try await fixture.client.prompt("fixture")
      Issue.record("EOF must not complete an acknowledged prompt successfully")
    } catch PiRPCClientError.processExited { }
    try await server.value
    await fixture.client.shutdown()
  }

  @Test func immediateSettlementBeforeWaitRegistrationSucceeds() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await fixture.serve(settles: true) }
    try await fixture.initialize()
    #expect(try await fixture.client.prompt("fixture") == .endTurn)
    try await server.value
    await fixture.client.shutdown()
  }

  @Test func cancelledAcknowledgedPromptThrowsAndClosesTransport() async throws {
    let fixture = PiPipeFixture()
    let hold = PiPromptGate()
    let server = Task { try await fixture.serve(settles: false, hold: hold) }
    try await fixture.initialize()
    let prompt = Task { try await fixture.client.prompt("fixture") }
    await hold.waitForPrompt()
    prompt.cancel()
    do { _ = try await prompt.value; Issue.record("cancelled prompt succeeded") }
    catch is CancellationError { }
    await hold.release()
    try await server.value
    await fixture.client.shutdown()
  }

  @Test func rejectedPromptThrowsCommandFailure() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await fixture.serve(settles: false, accepts: false) }
    try await fixture.initialize()
    do {
      _ = try await fixture.client.prompt("fixture")
      Issue.record("Rejected prompt must fail")
    } catch PiRPCClientError.commandFailed(let message) { #expect(message == "fixture rejection") }
    try await server.value
    await fixture.client.shutdown()
  }
}

private struct PiPipeFixture: Sendable {
  let commands = Pipe()
  let events = Pipe()
  let client: PiRPCClient
  init() {
    client = PiRPCClient(launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .pi,
      executableURL: URL(filePath: "/nonexistent-test-pi"), arguments: []),
      workingDirectory: URL(filePath: "/private/tmp"), input: commands.fileHandleForWriting,
      output: events.fileHandleForReading)
  }
  func initialize() async throws {
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/private/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
  }
  func serve(settles: Bool, accepts: Bool = true, hold: PiPromptGate? = nil) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let cursor = FixtureCommandReader(handle: commands.fileHandleForReading)
    while let line = try await cursor.next() {
      let command = try JSONSerialization.jsonObject(with: line) as! [String: Any]
      let type = command["type"] as! String
      let data: [String: Any] = type == "get_state" ? ["sessionId": "fixture-session"] : [:]
      var response: [String: Any] = ["type": "response", "id": command["id"]!, "success": true, "data": data]
      if type == "prompt", !accepts { response["success"] = false; response["error"] = "fixture rejection" }
      var output = try JSONSerialization.data(withJSONObject: response)
      output.append(10)
      if type == "prompt", settles { output.append(Data("{\"type\":\"agent_settled\"}\n".utf8)) }
      try events.fileHandleForWriting.write(contentsOf: output)
      if type == "prompt" {
        await hold?.pause()
        return
      }
    }
  }
}

private actor PiPromptGate {
  private var arrived = false
  private var observer: CheckedContinuation<Void, Never>?
  private var pending: CheckedContinuation<Void, Never>?
  func pause() async {
    arrived = true
    await withCheckedContinuation { continuation in
      pending = continuation
      observer?.resume()
      observer = nil
    }
  }
  func waitForPrompt() async {
    if arrived { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() { pending?.resume(); pending = nil }
}

/// Keep the fake server off Foundation's process-wide AsyncBytes I/O actor.
/// The client under test still uses its production ACPLineCursor.
private struct FixtureCommandReader: Sendable {
  let handle: FileHandle

  func next() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do { continuation.resume(returning: try readLine()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func readLine() throws -> Data? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var line = Data()
    while clock.now < deadline {
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, 100)
      if ready == 0 { continue }
      if ready < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var byte: UInt8 = 0
      let count = Darwin.read(handle.fileDescriptor, &byte, 1)
      if count == 0 { return line.isEmpty ? nil : line }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if byte == 10 { return line }
      line.append(byte)
      guard line.count <= 64 * 1_024 else { throw FixtureReadError.lineTooLarge }
    }
    throw FixtureReadError.timedOut
  }

  private enum FixtureReadError: Error { case timedOut, lineTooLarge }
}
