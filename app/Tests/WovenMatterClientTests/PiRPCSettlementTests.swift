import Darwin
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct PiRPCSettlementTests {
  @Test(.timeLimit(.minutes(1)))
  func stopDuringSteeringPreflightRetiresTheTransport() async throws {
    let fixture = PiPipeFixture(durable: true)
    let ready = AsyncStream<Void>.makeStream()
    let preflight = PiPromptGate()
    let server = Task { try await fixture.serveSteering(ready: ready.continuation, rejected: false, pending: preflight) }
    try await fixture.initialize()
    await fixture.client.setRunID("same-run")
    let original = Task { try await fixture.client.prompt("start") }
    for await _ in ready.stream { break }
    let input = Task { try await fixture.client.beginActiveInput(.init(text: "correction")) }
    await preflight.waitForPrompt()
    await fixture.client.cancel()
    await #expect(throws: CancellationError.self) { try await input.value }
    await #expect(throws: CancellationError.self) { try await original.value }
    await preflight.release()
    try await server.value
    await fixture.client.shutdown()
  }
  @Test(.timeLimit(.minutes(1)), arguments: ["accepted", "rejected", "uncertain"])
  func steeringOwnsSettlementAfterNativePreflight(outcome: String) async throws {
    let rejected = outcome != "accepted"
    let fixture = PiPipeFixture(durable: true)
    let ready = AsyncStream<Void>.makeStream()
    let server = Task { try await fixture.serveSteering(ready: ready.continuation, rejected: rejected, uncertain: outcome == "uncertain") }
    try await fixture.initialize()
    await fixture.client.setRunID("same-run")
    let collector = PiEventCollector()
    let original = Task { try await fixture.client.prompt("start", onEvent: { await collector.record($0) }) }
    for await _ in ready.stream { break }
    if rejected {
      do { _ = try await fixture.client.beginActiveInput(.init(text: "correction")); Issue.record("Expected admission error") }
      catch let error as PiRPCClientError {
        if case .deliveryUncertain = error { #expect(outcome == "uncertain") }
        else { #expect(outcome == "rejected") }
      }
    } else {
      let receipt = try await fixture.client.beginActiveInput(.init(text: "correction"))
      #expect(try await receipt.completion.value == .endTurn)
      #expect(await collector.values().contains(.assistantChunk("continued")))
    }
    #expect(try await original.value == .endTurn)
    await fixture.client.finishRun()
    await fixture.client.shutdown()
    try await server.value
  }

  @Test(.timeLimit(.minutes(1)))
  func stopDuringApprovalHistoryNeverSendsTheSelectedApproval() async throws {
    let history = PiPromptGate()
    let fixture = PiPipeFixture(recorder: { direction, data in
      if direction == "out",
         let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
         payload["type"] as? String == "extension_ui_response",
         payload["confirmed"] as? Bool == true {
        await history.pause()
      }
    })
    let server = Task { try await fixture.serveApprovalStop() }
    try await fixture.initialize()
    let fence = AgentDispatchFence()
    let prompt = Task {
      try await fixture.client.prompt("fixture", onPermission: { _ in "allow" }, dispatchFence: fence)
    }
    await history.waitForPrompt()
    let stop = Task { await fixture.client.cancel() }
    while !fence.isCancelled { await Task.yield() }
    await history.release()
    await stop.value
    #expect(try await prompt.value == .cancelled)
    await fixture.client.shutdown()
    try await server.value
  }

  @Test(.timeLimit(.minutes(1)))
  @MainActor
  func nativeAbortFailureKeepsStopBarrierClosedUntilExplicitRetry() async throws {
    let history = PiPromptGate()
    let fixture = PiPipeFixture(recorder: { direction, data in
      if direction == "in",
         let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
         payload["type"] as? String == "agent_start" { await history.pause() }
    })
    let server = Task { try await fixture.serveApprovalStop(rejectFirstAbort: true) }
    try await fixture.initialize()
    let prompt = Task { try await fixture.client.prompt("fixture", onPermission: { _ in nil }) }
    await history.waitForPrompt()
    await history.release()
    let barriers = AgentStopCoordinator()
    let first = barriers.begin(conversationID: "fixture") { try await fixture.client.stop() }
    do { try await first.value; Issue.record("Native abort rejection was ignored") }
    catch PiRPCClientError.commandFailed { }
    do { try await barriers.wait(conversationID: "fixture"); Issue.record("New input escaped a failed Stop") }
    catch PiRPCClientError.commandFailed { }
    let retry = barriers.begin(conversationID: "fixture") { try await fixture.client.stop() }
    try await retry.value
    try await barriers.wait(conversationID: "fixture")
    #expect(try await prompt.value == .cancelled)
    await fixture.client.shutdown()
    try await server.value
  }

  @Test(arguments: [false, true])
  func onlyDurableReconnectsRouteApprovalsBeforeTheNextPrompt(durable: Bool) async throws {
    let fixture = PiPipeFixture(durable: durable)
    await fixture.client.setResumePermissionHandler { request in
      #expect(durable)
      #expect(request.title == "Resume approval")
      return "allow"
    }
    let server = Task { try await fixture.serve(settles: true, resumeApproval: durable) }
    try await fixture.initialize()
    await fixture.client.shutdown()
    try await server.value
  }

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
    let input = AgentMessageInput(text: "capture this prompt", cliContext: .init(executablePath: "/tmp/wovenmatter", socketPath: nil, captureID: "captured-input"))
    #expect(try await fixture.client.prompt(input) == .endTurn)
    try await server.value
    await fixture.client.shutdown()
    #expect(capture.values.contains { $0.0 == "in" && $0.1.contains("future_native_event") })
    #expect(capture.values.contains { $0.0 == "out" && $0.1.contains("capture this prompt") })
    let wire = try #require(capture.values.first { $0.0 == "out" && $0.1.contains("capture this prompt") })
    let payload = try #require(JSONSerialization.jsonObject(with: Data(wire.1.utf8)) as? [String: Any])
    #expect(payload["message"] as? String == input.text)
    #expect(((payload["_meta"] as? [String: Any])?["wovenTools"] as? [String: Any])?["captureID"] as? String == "captured-input")
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

struct PiPipeFixture: Sendable {
  let commands = Pipe()
  let events = Pipe()
  let client: PiRPCClient
  private let capturesNativeHistory: Bool
  init(recorder: WorkspaceWireRecorder? = nil, durable: Bool = false) {
    var launch=LocalACPRuntimeLaunchConfiguration(runtimeKind:.pi,
      executableURL:URL(filePath:"/nonexistent-test-pi"),arguments:[],
      environment: durable ? ["WOVEN_DURABLE_REMOTE_ACP":"1"] : [:])
    launch.historyRecorder=recorder
    capturesNativeHistory = recorder != nil
    client = PiRPCClient(launch: launch,
      workingDirectory: URL(filePath: "/private/tmp"), input: commands.fileHandleForWriting,
      output: events.fileHandleForReading)
  }
  func emit(_ object: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
    try events.fileHandleForWriting.write(contentsOf: data)
  }
  func initialize() async throws {
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/private/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
  }
  fileprivate func serveSteering(ready: AsyncStream<Void>.Continuation, rejected: Bool, pending: PiPromptGate? = nil, uncertain: Bool = false) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let cursor = FixtureCommandReader(handle: commands.fileHandleForReading)
    var started = false
    var steered = false
    var pendingPreflight: Task<Void, Never>?
    while let line = try await cursor.next() {
      let command = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
      let type = command["type"] as? String
      var response: [String: Any] = ["type": "response", "id": command["id"]!, "success": true, "data": [:]]
      if type == "get_entries" { response["data"] = ["entries": []] }
      if type == "abort", let pendingPreflight {
        #expect((command["_meta"] as? [String: Bool])?["wovenStopPreflight"] == true)
        try emit(response)
        await pendingPreflight.value
        return
      }
      if type == "get_state" {
        response["data"] = ["sessionId": "fixture-session", "isStreaming": started && !steered,
                            "isCompacting": false, "pendingMessageCount": 0]
      }
      if type == "prompt", !started {
        #expect((command["_meta"] as? [String: String])?["wovenRunID"] == "same-run")
        started = true
        try emit(response)
        try emit(["type": "agent_start"])
        ready.yield(())
        continue
      }
      if type == "prompt" {
        #expect(command["streamingBehavior"] as? String == "steer")
        #expect((command["_meta"] as? [String: String])?["wovenRunID"] == "same-run")
        steered = true
        if let pending { pendingPreflight = Task { await pending.pause() }; continue }
        // The old loop ends while the native extension input hook is running.
        try emit(["type": "agent_settled"])
        if rejected { response["success"] = false; response["error"] = "rejected correction" }
        if uncertain { response["_meta"] = ["deliveryUncertain": true] }
        try emit(response)
        if !rejected {
          try emit(["type": "agent_start"])
          try emit(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": "continued"]])
          try emit(["type": "agent_settled"])
        }
        continue
      }
      try emit(response)
    }
  }

  func serveApprovalStop(rejectFirstAbort: Bool = false) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let cursor = FixtureCommandReader(handle: commands.fileHandleForReading)
    var started = false
    var receivedCancellation = false
    var rejectedAbort = false
    while let line = try await cursor.next() {
      let command = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
      let type = command["type"] as? String
      if type == "extension_ui_response" {
        #expect(command["confirmed"] as? Bool == false)
        #expect(command["cancelled"] as? Bool == true)
        receivedCancellation = true
        continue
      }
      if type == "prompt" { started = true }
      if type == "abort", rejectFirstAbort, !rejectedAbort {
        rejectedAbort = true
        try emit(["type": "response", "id": command["id"]!, "success": false, "error": "fixture abort rejection"])
        continue
      }
      let data: [String: Any] = type == "get_state"
        ? ["sessionId": "fixture-session", "isStreaming": started] : [:]
      var response: [String: Any] = ["type": "response", "id": command["id"]!, "success": true, "data": data]
      if type == "get_entries" { response["data"] = ["entries": []] }
      try emit(response)
      if type == "get_state", started {
        try emit(["type": "agent_start"])
        try emit(["type": "extension_ui_request", "id": "approval", "method": "confirm", "title": "Allow tool?"])
      }
      if type == "abort" {
        #expect(receivedCancellation)
        started = false
        try emit(["type": "agent_settled"])
      }
    }
  }

  func serve(settles: Bool, accepts: Bool = true, hold: PiPromptGate? = nil,
             streamLines: [String] = [], advertisesConfiguration: Bool = false, recovery: Bool = false, resumeApproval: Bool? = nil) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let cursor = FixtureCommandReader(handle: commands.fileHandleForReading)
    var settled = false
    while let line = try await cursor.next() {
      let command = try JSONSerialization.jsonObject(with: line) as! [String: Any]
      let type = command["type"] as! String
      var data: [String: Any]
      switch type {
      case "prompt":
        data = ["disposition": "started"]
      case "get_state":
        if let resumeApproval {
          try events.fileHandleForWriting.write(contentsOf: Data(
            #"{"type":"extension_ui_request","id":"pending-approval","method":"confirm","title":"Resume approval"}"#.utf8) + Data([10]))
          let reply = try #require(try await cursor.next())
          let value = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
          #expect(value["type"] as? String == "extension_ui_response")
          #expect(value["id"] as? String == "pending-approval")
          #expect(value["confirmed"] as? Bool == resumeApproval)
        }
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
      if type == "get_entries" { response["data"] = ["entries": []] }
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
        guard accepts && settles && capturesNativeHistory else { return }
        settled = true
      } else if type == "get_entries", settled { return }
    }
  }
}

actor PiPromptGate {
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
struct FixtureCommandReader: Sendable {
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
  @Test(arguments: [("/search", "info"), ("/search on", "info"), ("enable search", "info"),
                    ("/search", "warning"), ("/search", "error")])
  func handledInputPublishesNotificationAndAllowsNextPrompt(_ sample: (String, String)) async throws {
    let (text, severity) = sample
    let fixture = PiPipeFixture()
    let server = Task {
      try await serveCommands(fixture, firstPrompt: text, severity: severity)
    }
    try await fixture.initialize()
    let collector = PiEventCollector()
    #expect(try await fixture.client.prompt(text) { await collector.record($0) } == .endTurn)
    let events = await collector.values()
    #expect(events.contains { event in
      guard case .activity(let activity, _) = event else { return false }
      return activity.kind == .activity && activity.content == "Search is on."
        && activity.status == (severity == "error" ? "failed" : "completed") && activity.detail == severity
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
        data = ["disposition": normalStartup || prompts > 1 ? "started" : "handled"]
        #expect(command["message"] as? String == (prompts == 1 ? firstPrompt : "ordinary message"))
        if let pending { await pending.pause(); return }
        if prompts == 1 && !normalStartup {
          try fixture.emit(["type": "extension_ui_request", "id": "notice", "method": "notify",
                     "message": "Search is on.", "notifyType": severity])
        }
      }
      if type == "get_state" {
        data = ["sessionId": "fixture-session", "isStreaming": (normalStartup || stopAfterACK != nil) && prompts > 0,
                "isCompacting": false, "pendingMessageCount": 0]
      }
      if type == "get_entries" { data = ["entries": []] }
      try fixture.emit(["type": "response", "id": command["id"]!, "success": true, "data": data])
      if type == "get_state", prompts == 1, let stopAfterACK {
        Task { await stopAfterACK.pause() }
      }
      if (normalStartup && type == "get_state" && prompts > 0) || (type == "prompt" && prompts == 2) {
        // State reports active before the first agent_start reaches the client.
        try fixture.emit(["type": "agent_start"])
        try fixture.emit(["type": "message_end", "message": ["role": "assistant", "content": "finished"]])
        try fixture.emit(["type": "agent_settled"])
      }
    }
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

@Suite(.timeLimit(.minutes(1)))
struct PiQuestionAndCompactionTests {
  @Test(arguments: ["select", "input", "editor", "empty", "confirm", "stop", "timeout"])
  func nativeDialogsPreserveValuesAndStopUnansweredUI(method: String) async throws {
    let fixture = PiPipeFixture()
    let opened = AsyncStream<Void>.makeStream()
    let server = Task { try await serve(fixture, method: method) }
    try await fixture.initialize()
    let prompt = Task { try await fixture.client.prompt("fixture", onPermission: { _ in
      #expect(method == "confirm"); return "reject"
    }, onInteraction: { request in
      guard case .form(let form) = request else { Issue.record("Expected question form"); return .cancelled }
      #expect(method != "confirm" && method != "timeout")
      if method == "stop" {
        opened.continuation.yield(())
        try? await Task.sleep(for: .seconds(30))
        return .formValues(["value": .string("late answer")])
      }
      if method == "editor" {
        #expect(form.fields.first?.multiline == true)
        #expect(form.fields.first?.initialValue == .string("  initial\ntext  "))
      }
      return .formValues(["value": .string(method == "select" ? "reject" : method == "empty" ? "" : "  answer\ntext  ")])
    }) }
    if method == "stop" {
      for await _ in opened.stream { break }
      try await fixture.client.stop()
    }
    #expect(try await prompt.value == (method == "stop" ? .cancelled : .endTurn))
    await fixture.client.shutdown(); opened.continuation.finish(); try await server.value
  }
  @Test func eofCancelsQueuedDialogsWithoutHoldingSettlement() async throws {
    let fixture = PiPipeFixture()
    let server = Task {
      let reader = FixtureCommandReader(handle: fixture.commands.fileHandleForReading)
      defer { try? fixture.events.fileHandleForWriting.close() }
      while let line = try await reader.next() {
        let command = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let type = command["type"] as? String
        let data: [String: Any] = type == "get_state" ? ["sessionId": "fixture-session", "isStreaming": true, "isCompacting": false, "pendingMessageCount": 0] : [:]
        try fixture.emit(["type": "response", "id": command["id"]!, "success": true, "data": data])
        if type == "prompt" {
          try fixture.emit(["type": "agent_start"])
          for id in ["first", "queued"] { try fixture.emit(["type": "extension_ui_request", "id": id, "method": "editor", "title": id]) }
          try fixture.emit(["type": "agent_settled"])
          return
        }
      }
    }
    try await fixture.initialize()
    _ = try? await fixture.client.prompt("fixture", onInteraction: { request in
      if case .form(let form) = request { #expect(form.message != "queued") }
      try? await Task.sleep(for: .seconds(30)); return .cancelled
    })
    await fixture.client.shutdown(); try await server.value
  }
  @Test func nativeCompactionProjectsProgressWithoutSettlingAndAbortedSettlementWins() async throws {
    let fixture = PiPipeFixture()
    let server = Task { try await serve(fixture, method: "compaction") }
    try await fixture.initialize()
    let events = PiEventCollector()
    #expect(try await fixture.client.prompt("fixture", onEvent: { await events.record($0) }) == .cancelled)
    #expect(await events.values().contains(.programStatus(ProgramStatus(state: .working, app: "pi", message: "Compacting context"), runID: nil)))
    #expect(await events.values().contains { if case .activity(let activity, _) = $0 { return activity.status == "failed" && activity.content?.contains("secret.example") == false }; return false })
    await fixture.client.shutdown(); try await server.value
  }
  private func serve(_ fixture: PiPipeFixture, method: String) async throws {
    defer { try? fixture.events.fileHandleForWriting.close() }
    let reader = FixtureCommandReader(handle: fixture.commands.fileHandleForReading)
    var started = false, uiAnswered = false, abortID: Any?
    while let line = try await reader.next() {
      let command = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
      let type = command["type"] as? String
      if type == "extension_ui_response" {
        #expect(command["id"] as? String == "question")
        uiAnswered = true
        if method == "stop" || method == "timeout" { #expect(command["cancelled"] as? Bool == true) }
        else if method == "confirm" { #expect(command["confirmed"] as? Bool == false); #expect(command["cancelled"] == nil) }
        else { #expect(command["value"] as? String == (method == "select" ? "reject" : method == "empty" ? "" : "  answer\ntext  ")); #expect(command["cancelled"] == nil) }
        if method != "stop" { try fixture.emit(["type": "agent_settled"]); continue }
      } else if type == "abort" { abortID = command["id"] }
      else {
        var data: [String: Any] = [:]
        if type == "get_entries" { data = ["entries": []] }
        if type == "get_state" { data = ["sessionId": "fixture-session", "isStreaming": started, "isCompacting": false, "pendingMessageCount": 0] }
        try fixture.emit(["type": "response", "id": command["id"]!, "success": true, "data": data])
        if type == "prompt" {
          started = true
          try fixture.emit(["type": "agent_start"])
          if method == "compaction" {
            try fixture.emit(["type": "compaction_start"])
            try fixture.emit(["type": "compaction_end", "errorMessage": "Failure https://secret.example/token"])
            try fixture.emit(["type": "message_end", "message": ["role": "assistant", "content": "answer", "stopReason": "error", "errorMessage": "Prior error before abort"]])
            try fixture.emit(["type": "agent_settled", "aborted": true])
          } else {
            try fixture.emit(["type": "extension_ui_request", "id": "question", "method": ["empty", "stop", "timeout"].contains(method) ? "input" : method,
                "title": "Question", "options": ["reject", "other"], "prefill": "  initial\ntext  ", "timeout": method == "timeout" ? 0 : 60000])
          }
        }
      }
      if method == "stop", uiAnswered, let abortID {
        try fixture.emit(["type": "response", "id": abortID, "success": true, "data": [:]])
        try fixture.emit(["type": "agent_settled", "aborted": true])
        return
      }
    }
  }
}
