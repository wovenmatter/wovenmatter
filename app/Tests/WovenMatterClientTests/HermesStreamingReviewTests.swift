import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HermesStreamingReviewTests {

  @Test(arguments: ["send", "skill", "prefill", "exec", "plugin"])
  func commandFeedbackIsPreservedWithoutBecomingAnAssistantReply(_ outcome: String) async throws {
    let transport = HermesStreamingTransport(commandResult: [
      "type": .string(outcome), "message": "Command prompt or draft",
      "notice": "Native command notice", "warning": "Native command warning"
    ])
    let client = HermesGatewayClient(
      launch: .init(runtimeKind: .hermes, executableURL: URL(filePath: "/fixture/hermes"), arguments: []),
      transport: transport, home: "/tmp/hermes-command-review"
    )
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
    let output = HermesStreamingEvents()
    let turn = Task {
      try await client.prompt(.init(text: "/review"), onEvent: { await output.record($0) },
        onPermission: nil, onInteraction: nil)
    }
    if outcome == "send" || outcome == "skill" {
      try await transport.waitForSubmit()
      await transport.event("message.complete", ["text": "Actual model response"])
    }
    #expect(try await turn.value == .endTurn)
    let events = await output.allEvents()
    let feedback = events.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .activity else { return nil }
      return activity
    }
    #expect(feedback.map(\.content) == ["Native command warning\n\nNative command notice"])
    #expect(!events.contains(.assistantSnapshot("Native command notice")))
    #expect(events.contains(.composerPrefill("Command prompt or draft")) == (outcome == "prefill"))
    #expect(await transport.didSubmit() == (outcome == "send" || outcome == "skill"))
    await transport.resetSubmission()
    let next = Task { try await client.prompt(.init(text: "ordinary message"),
      onEvent: nil, onPermission: nil, onInteraction: nil) }
    try await transport.waitForSubmit()
    await transport.event("message.complete", ["text": "Follow-up"])
    #expect(try await next.value == .endTurn)
    await client.shutdown()
  }

  @Test(arguments: [false, true], ["send", "skill", "prefill", "exec", "plugin"])
  func cancelledCommandCannotSubmitItsReturnedPrompt(duringFeedback: Bool, outcome: String) async throws {
    let transport = HermesStreamingTransport(
      commandResult: ["type": .string(outcome), "message": "Must not be submitted", "notice": "Command notice"],
      holdCommand: !duringFeedback)
    let client = HermesGatewayClient(
      launch: .init(runtimeKind: .hermes, executableURL: URL(filePath: "/fixture/hermes"), arguments: []),
      transport: transport, home: "/tmp/hermes-command-review"
    )
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
    let turn = Task { try await client.prompt(.init(text: "/review"),
      onEvent: { event in
        if duringFeedback, case .activity = event { try await client.cancel() }
      }, onPermission: nil, onInteraction: nil) }
    if !duringFeedback {
      try await transport.waitForCommand()
      try await client.cancel()
      await transport.releaseCommand()
    }
    #expect(try await turn.value == .cancelled)
    #expect(await !transport.didSubmit())
    await client.shutdown()
  }

  @Test func streamedReasoningPhasesDoNotDuplicateCanonicalCompletion() async throws {
    let transport = HermesStreamingTransport()
    let client = HermesGatewayClient(
      launch: .init(runtimeKind: .hermes, executableURL: URL(filePath: "/fixture/hermes"), arguments: []),
      transport: transport, home: "/tmp/hermes-stream-review"
    )
    _ = try await client.initializeSession(
      workingDirectory: URL(filePath: "/tmp"), existingSessionID: nil,
      title: nil, systemPrompt: nil
    )
    let output = HermesStreamingEvents()
    let turn = Task {
      try await client.prompt(.init(text: "fixture"), onEvent: { await output.record($0) },
                              onPermission: nil, onInteraction: nil)
    }
    try await transport.waitForSubmit()
    await transport.event("reasoning.delta", ["text": "phase one"])
    await transport.event("message.delta", ["text": " interim "])
    await transport.event("message.interim", ["text": " interim "])
    await transport.event("reasoning.delta", ["text": "phase two"])
    await transport.event("message.complete", ["text": " final ", "reasoning": "phase two"])
    #expect(try await turn.value == .endTurn)

    let thoughts = await output.thoughts()
    #expect(thoughts.count == 2)
    #expect(thoughts[0].id != thoughts[1].id)
    #expect(thoughts.map(\.content) == ["phase one", "phase two"])
    let assistant = await output.assistantEvents()
    #expect(assistant.contains(.assistantSnapshot(" interim \n\n")))
    #expect(assistant.contains(.assistantSnapshot(" interim \n\n final ")))
    await client.shutdown()
  }

  @Test func divergentCanonicalReasoningIsPreservedAfterStreamedPhase() async throws {
    let transport = HermesStreamingTransport()
    let client = HermesGatewayClient(
      launch: .init(runtimeKind: .hermes, executableURL: URL(filePath: "/fixture/hermes"), arguments: []),
      transport: transport, home: "/tmp/hermes-stream-review"
    )
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/tmp"),
                                           existingSessionID: nil, title: nil, systemPrompt: nil)
    let output = HermesStreamingEvents()
    let turn = Task {
      try await client.prompt(.init(text: "fixture"), onEvent: { await output.record($0) },
                              onPermission: nil, onInteraction: nil)
    }
    try await transport.waitForSubmit()
    await transport.event("reasoning.delta", ["text": "streamed fragment"])
    await transport.event("message.complete", ["text": "answer", "reasoning": "canonical replacement"])
    #expect(try await turn.value == .endTurn)
    let thoughts = await output.thoughts()
    #expect(thoughts.count == 2)
    #expect(thoughts[0].content == "streamed fragment")
    #expect(thoughts[1].content == "canonical replacement")
    #expect(thoughts[0].id != thoughts[1].id)
    await client.shutdown()
  }
}

private actor HermesStreamingEvents {
  private var values: [LocalACPEvent] = []
  func record(_ event: LocalACPEvent) { values.append(event) }
  func allEvents() -> [LocalACPEvent] { values }
  func thoughts() -> [AgentRunActivity] {
    values.compactMap {
      guard case .activity(let activity, _) = $0, activity.kind == .thought else { return nil }
      return activity
    }
  }
  func assistantEvents() -> [LocalACPEvent] {
    values.filter {
      switch $0 { case .assistantChunk, .assistantSnapshot, .assistantBoundary: true; default: false }
    }
  }
}

private actor HermesStreamingTransport: HermesGatewayTransport {
  var epoch: String? = "fixture-epoch"
  var isConnected = false
  private var handler: HermesGatewayRPC.EventHandler?
  private var submitted = false
  private var sequence = 0
  private let commandResult: HermesValue?
  private let holdCommand: Bool
  private var commandWaiter: CheckedContinuation<Void, Never>?
  private var commandRequested = false

  init(commandResult: HermesValue? = nil, holdCommand: Bool = false) {
    self.commandResult = commandResult
    self.holdCommand = holdCommand
  }
  func didSubmit() -> Bool { submitted }
  func resetSubmission() { submitted = false }
  func releaseCommand() { commandWaiter?.resume(); commandWaiter = nil }
  func waitForCommand() async throws {
    for _ in 0..<200 {
      if commandRequested { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw HermesGatewayError.message("fixture command timeout")
  }

  func setHandlers(event: HermesGatewayRPC.EventHandler?,
                   disconnected: (@Sendable () async -> Void)?,
                   request: HermesGatewayRPC.EventHandler?) { handler = event }
  func connect() { isConnected = true }
  func disconnect() { isConnected = false }
  func respond(id: String, result: HermesValue) {}
  func call(_ method: String, _ params: HermesValue) async -> HermesValue {
    switch method {
    case "session.create": return ["session_id": "live", "stored_session_id": "stored", "running": .bool(false)]
    case "session.events.since": return ["latest_seq": .number(Double(sequence)), "epoch": "fixture-epoch"]
    case "commands.catalog":
      return commandResult == nil ? [:] : ["pairs": .array([.array(["/review", "Review"])])]
    case "command.dispatch":
      commandRequested = true
      if holdCommand { await withCheckedContinuation { commandWaiter = $0 } }
      return commandResult ?? [:]
    case "prompt.submit": submitted = true; return [:]
    default: return [:]
    }
  }
  func event(_ type: String, _ payload: HermesValue) async {
    sequence += 1
    await handler?(["session_id": "live", "seq": .number(Double(sequence)),
                    "type": .string(type), "payload": payload])
  }
  func waitForSubmit() async throws {
    for _ in 0..<200 {
      if submitted { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw HermesGatewayError.message("fixture submit timeout")
  }
}
