import Darwin
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct PiRPCSettlementTests {
  @Test func durableRelayCarriesStableRunAndReturnsRecovery() async throws {
    let capture = PiWireCapture()
    let fixture = PiPipeFixture(recorder: { capture.append($0,$1) }, durable: true)
    let server = Task { try await fixture.serve(settles: true, recovery: true) }
    let initialized = try await fixture.client.initializeSession(workingDirectory: URL(filePath:"/private/tmp"),
      existingSessionID:"fixture-session",title:nil,systemPrompt:nil)
    #expect(initialized.recoveredDefaultAgentRuns.first?.runID == "prior-run")
    #expect(initialized.recoveredDefaultAgentRuns.first?.content == "saved result")
    await fixture.client.setRunID("current-run")
    #expect(try await fixture.client.prompt("fixture") == .endTurn)
    try await server.value
    await fixture.client.shutdown()
    #expect(capture.values.contains { $0.0 == "out" && $0.1.contains("wovenRunID") && $0.1.contains("current-run") })
  }

  @Test func capturesUnknownNativeEventsAndOutboundPromptsBeforeProjection() async throws {
    let capture=PiWireCapture()
    let fixture=PiPipeFixture(recorder:{ direction,data in capture.append(direction,data) })
    let server=Task { try await fixture.serve(settles:true) }
    try await fixture.initialize()
    #expect(try await fixture.client.prompt("capture this prompt") == .endTurn)
    try await server.value
    await fixture.client.shutdown()
    #expect(capture.values.contains { $0.0 == "in" && $0.1.contains("future_native_event") })
    #expect(capture.values.contains { $0.0 == "out" && $0.1.contains("capture this prompt") })
  }

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

  @Test func streamingKeepsWhitespaceBoundariesAndReasoningPhases() async throws {
    let fixture = PiPipeFixture()
    let lines = [
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":" first\n"}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"  answer "}}"#,
      #"{"type":"message_end","message":{"role":"assistant"}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":" second "}}"#,
      #"{"type":"tool_execution_update","toolCallId":"tool-1","toolName":"shell","args":{"command":"pwd"},"partialResult":{"content":[{"text":" /tmp\n"}]}}"#,
    ]
    let server = Task { try await fixture.serve(settles: true, streamLines: lines) }
    try await fixture.initialize()
    let collector = PiEventCollector()
    _ = try await fixture.client.prompt("fixture") { event in await collector.record(event) }
    try await server.value
    let events = await collector.values()
    #expect(events.count == 6)
    #expect(events[1] == .assistantChunk("  answer "))
    #expect(events[2] == .assistantSnapshot(""))
    #expect(events[3] == .assistantBoundary)
    guard case .activity(let first, _) = events[0],
          case .activity(let second, _) = events[4] else {
      Issue.record("Expected two reasoning activities")
      return
    }
    #expect(first.content == " first\n")
    #expect(second.content == " second ")
    #expect(first.id != second.id)
    guard case .activity(let tool, _) = events[5] else {
      Issue.record("Expected tool progress activity")
      return
    }
    #expect(tool.phase == "update")
    #expect(tool.status == "running")
    #expect(tool.content == " /tmp\n")
    #expect(tool.rawInputJSON == #"{"command":"pwd"}"#)
    await fixture.client.shutdown()
  }

  @Test func configurationKeepsQualifiedModelsAndCurrentModelThinkingLevels() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await fixture.serve(settles: false, advertisesConfiguration: true) }
    let initialized = try await fixture.client.initializeSession(
      workingDirectory: URL(filePath: "/private/tmp"),
      existingSessionID: nil,
      title: nil,
      systemPrompt: nil
    )
    #expect(initialized.configuration.model == "anthropic/shared-model")
    #expect(initialized.configuration.modelOptions == [
      "anthropic/shared-model",
      "copilot/shared-model",
      "custom/plain-model",
    ])
    #expect(initialized.configuration.modelOptionMetadata == [
      "anthropic/shared-model": SessionOptionMetadata(
        name: "Shared Model (anthropic)",
        description: "Direct provider"
      ),
      "copilot/shared-model": SessionOptionMetadata(
        name: "Shared Model (copilot)",
        description: "Subscription route"
      ),
      "custom/plain-model": SessionOptionMetadata(
        description: "No supplied display name"
      ),
    ])
    #expect(initialized.configuration.slashCommands == [
      LocalACPSlashCommand(name: "search", detail: "Extension command"),
      LocalACPSlashCommand(name: "skill:review", detail: "Review skill")
    ])
    #expect(initialized.configuration.thinking == "high")
    #expect(initialized.configuration.thinkingOptions == ["off", "high", "max"])
    #expect(initialized.configuration.thinkingOptionMetadata.isEmpty)
    await fixture.client.shutdown()
    try await server.value
  }
}

private actor PiEventCollector {
  private var events: [LocalACPEvent] = []
  func record(_ event: LocalACPEvent) { events.append(event) }
  func values() -> [LocalACPEvent] { events }
}

private struct PiPipeFixture: Sendable {
  let commands = Pipe()
  let events = Pipe()
  let client: PiRPCClient
  init(recorder: WorkspaceWireRecorder? = nil, durable: Bool = false) {
    var launch=LocalACPRuntimeLaunchConfiguration(runtimeKind:.pi,
      executableURL:URL(filePath:"/nonexistent-test-pi"),arguments:[],
      environment: durable ? ["WOVEN_DURABLE_REMOTE_ACP":"1"] : [:])
    launch.historyRecorder=recorder
    client = PiRPCClient(launch: launch,
      workingDirectory: URL(filePath: "/private/tmp"), input: commands.fileHandleForWriting,
      output: events.fileHandleForReading)
  }
  func initialize() async throws {
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/private/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
  }
  func serve(settles: Bool, accepts: Bool = true, hold: PiPromptGate? = nil,
             streamLines: [String] = [], advertisesConfiguration: Bool = false, recovery: Bool = false) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let cursor = FixtureCommandReader(handle: commands.fileHandleForReading)
    while let line = try await cursor.next() {
      let command = try JSONSerialization.jsonObject(with: line) as! [String: Any]
      let type = command["type"] as! String
      var data: [String: Any]
      switch type {
      case "get_state":
        data = advertisesConfiguration ? [
          "sessionId": "fixture-session",
          "model": ["provider": "anthropic", "id": "shared-model"],
          "thinkingLevel": "high",
        ] : ["sessionId": "fixture-session"]
      case "get_available_models" where advertisesConfiguration:
        data = ["models": [
          [
            "provider": "anthropic", "id": "shared-model",
            "name": "Shared Model", "description": "Direct provider",
          ],
          [
            "provider": "copilot", "id": "shared-model",
            "name": "Shared Model", "description": "Subscription route",
          ],
          [
            "provider": "custom", "id": "plain-model",
            "description": "No supplied display name",
          ],
        ]]
      case "get_commands" where advertisesConfiguration:
        data = ["commands": [
          ["name": "search", "description": "Extension command", "source": "extension"],
          ["name": "search", "description": "Shadowed prompt template", "source": "prompt"],
          ["name": "skill:review", "description": "Review skill", "source": "skill"],
          ["name": ""], ["name": "invalid command"]
        ]]
      case "get_available_thinking_levels" where advertisesConfiguration:
        // Pi returns only the levels supported by the currently selected model.
        data = ["levels": ["off", "high", "max"]]
      default:
        data = [:]
      }
      if recovery, type == "get_state" {
        data["_meta"] = ["recoveredRuns": [["runID":"prior-run","content":"saved result"]]]
      }
      var response: [String: Any] = ["type": "response", "id": command["id"]!, "success": true, "data": data]
      if type == "prompt", !accepts { response["success"] = false; response["error"] = "fixture rejection" }
      var output = try JSONSerialization.data(withJSONObject: response)
      output.append(10)
      if type == "prompt" {
        for line in streamLines { output.append(Data("\(line)\n".utf8)) }
      }
      if type == "prompt", settles {
        output.append(Data("{\"type\":\"future_native_event\",\"customPayload\":\"preserve this\"}\n".utf8))
        output.append(Data("{\"type\":\"agent_settled\"}\n".utf8))
      }
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
    // The full suite runs hundreds of tests concurrently on CI. This is the
    // fake peer's idle budget, not a product timeout; do not close the pipe
    // while the resumed client is merely waiting for executor time.
    let deadline = clock.now.advanced(by: .seconds(30))
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

struct PiHandledCommandTests {
  @Test(arguments: ["/search", "/search on", "enable search"])
  func handledInputPublishesNotificationAndAllowsNextPrompt(_ text: String) async throws {
    let fixture = PiPipeFixture()
    let server = Task {
      try await serveCommands(fixture, firstPrompt: text)
    }
    try await fixture.initialize()
    let collector = PiEventCollector()
    #expect(try await fixture.client.prompt(text) { await collector.record($0) } == .endTurn)
    let events = await collector.values()
    #expect(events.contains { event in
      guard case .activity(let activity, _) = event else { return false }
      return activity.kind == .activity && activity.content == "Search is on."
    })
    #expect(!events.contains { event in
      if case .assistantChunk = event { return true }
      if case .assistantSnapshot = event { return true }
      return false
    })
    #expect(try await fixture.client.prompt("ordinary message") == .endTurn)
    await fixture.client.shutdown()
    try await server.value
  }

  @Test(arguments: ["warning", "error"])
  func notificationSeverityIsVisible(_ severity: String) async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await serveCommands(fixture, firstPrompt: "/search", severity: severity) }
    try await fixture.initialize()
    let collector = PiEventCollector()
    _ = try await fixture.client.prompt("/search") { await collector.record($0) }
    #expect(await collector.values().contains { event in
      guard case .activity(let activity, _) = event else { return false }
      return activity.status == (severity == "error" ? "failed" : "completed")
        && activity.detail == severity
    })
    await fixture.client.shutdown()
    try await server.value
  }

  @Test func stopAcknowledgedCommandThenOrdinaryMessageUsesSameTransport() async throws {
    let fixture = PiPipeFixture()
    let gate = PiPromptGate()
    let server = Task { try await serveCommands(fixture, firstPrompt: "/search", stopAfterACK: gate) }
    try await fixture.initialize()
    let command = Task { try await fixture.client.prompt("/search") }
    await gate.waitForPrompt()
    await fixture.client.cancel()
    #expect(try await command.value == .cancelled)
    #expect(try await fixture.client.prompt("ordinary message") == .endTurn)
    await fixture.client.shutdown()
    await gate.release()
    try await server.value
  }

  @Test func normalStartupBeforeAgentStartStillWaitsForSettlement() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await serveCommands(fixture, firstPrompt: "ordinary message", normalStartup: true) }
    try await fixture.initialize()
    let collector = PiEventCollector()
    #expect(try await fixture.client.prompt("ordinary message") { await collector.record($0) } == .endTurn)
    #expect(await collector.values().contains(.assistantSnapshot("finished")))
    await fixture.client.shutdown()
    try await server.value
  }

  @Test func stopBeforeCommandAcknowledgementRetiresTransportAndResumeWorks() async throws {
    let fixture = PiPipeFixture()
    let gate = PiPromptGate()
    let server = Task { try await serveCommands(fixture, firstPrompt: "/search", pending: gate) }
    try await fixture.initialize()
    let command = Task { try await fixture.client.prompt("/search") }
    await gate.waitForPrompt()
    await fixture.client.cancel()
    do {
      _ = try await command.value
      Issue.record("Pending command should be cancelled")
    } catch is CancellationError { }
    // A late extension completion must not be reusable by a new run.
    do {
      _ = try await fixture.client.prompt("ordinary message")
      Issue.record("Cancelled transport should be retired")
    } catch { }
    await gate.release()
    try await server.value

    let resumed = PiPipeFixture()
    let resumedServer = Task { try await serveCommands(resumed, firstPrompt: "ordinary message", normalStartup: true) }
    let session = try await resumed.client.initializeSession(
      workingDirectory: URL(filePath: "/private/tmp"), existingSessionID: "fixture-session",
      title: nil, systemPrompt: nil)
    #expect(session.loadedExistingSession)
    #expect(session.sessionID == "fixture-session")
    #expect(try await resumed.client.prompt("ordinary message") == .endTurn)
    await resumed.client.shutdown()
    try await resumedServer.value
  }

  private func serveCommands(_ fixture: PiPipeFixture, firstPrompt: String,
                             normalStartup: Bool = false, pending: PiPromptGate? = nil,
                             severity: String = "info", stopAfterACK: PiPromptGate? = nil) async throws {
    defer { try? fixture.events.fileHandleForWriting.close() }
    let reader = FixtureCommandReader(handle: fixture.commands.fileHandleForReading)
    var prompts = 0
    while let line = try await reader.next() {
      let command = try JSONSerialization.jsonObject(with: line) as! [String: Any]
      let type = command["type"] as! String
      var data: [String: Any] = [:]
      if type == "prompt" {
        prompts += 1
        #expect(command["message"] as? String == (prompts == 1 ? firstPrompt : "ordinary message"))
        if let pending { await pending.pause(); return }
        if prompts == 1 && !normalStartup {
          try write(["type": "extension_ui_request", "id": "notice", "method": "notify",
                     "message": "Search is on.", "notifyType": severity], to: fixture)
        }
      }
      if type == "get_state" {
        data = ["sessionId": "fixture-session", "isStreaming": (normalStartup || stopAfterACK != nil) && prompts > 0,
                "isCompacting": false, "pendingMessageCount": 0]
      }
      try write(["type": "response", "id": command["id"]!, "success": true, "data": data], to: fixture)
      if type == "get_state", prompts == 1, let stopAfterACK {
        Task { await stopAfterACK.pause() }
      }
      if (normalStartup && type == "get_state" && prompts > 0) || (type == "prompt" && prompts == 2) {
        // State reports active before the first agent_start reaches the client.
        try write(["type": "agent_start"], to: fixture)
        try write(["type": "message_end", "message": ["role": "assistant", "content": "finished"]], to: fixture)
        try write(["type": "agent_settled"], to: fixture)
      }
    }
  }

  private func write(_ object: [String: Any], to fixture: PiPipeFixture) throws {
    var bytes = try JSONSerialization.data(withJSONObject: object)
    bytes.append(10)
    try fixture.events.fileHandleForWriting.write(contentsOf: bytes)
  }
}

private final class PiWireCapture: @unchecked Sendable {
  private let lock=NSLock()
  private var captured:[(String,String)]=[]
  var values:[(String,String)] { lock.withLock { captured } }
  func append(_ direction:String,_ data:Data) {
    lock.withLock { captured.append((direction,String(decoding:data,as:UTF8.self))) }
  }
}
