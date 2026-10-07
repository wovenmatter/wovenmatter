import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HermesStreamingReviewTests {

  @Test(arguments: ["send", "skill", "prefill", "exec", "plugin"])
  func commandFeedbackIsPreservedWithoutBecomingAnAssistantReply(_ outcome: String) async throws {
    let transport = HermesTransportFixture(commandResult: [
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
      await transport.event(type: "message.complete", payload: ["text": "Actual model response"])
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
    await transport.event(type: "message.complete", payload: ["text": "Follow-up"])
    #expect(try await next.value == .endTurn)
    await client.shutdown()
  }

  @Test(arguments: [false, true], ["send", "skill", "prefill", "exec", "plugin"])
  func cancelledCommandCannotSubmitItsReturnedPrompt(duringFeedback: Bool, outcome: String) async throws {
    let transport = HermesTransportFixture(
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
    let transport = HermesTransportFixture()
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
    await transport.event(type: "reasoning.delta", payload: ["text": "phase one"])
    await transport.event(type: "message.delta", payload: ["text": " interim "])
    await transport.event(type: "message.interim", payload: ["text": " interim "])
    await transport.event(type: "reasoning.delta", payload: ["text": "phase two"])
    await transport.event(type: "message.complete", payload: ["text": " final ", "reasoning": "phase two"])
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
    let transport = HermesTransportFixture()
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
    await transport.event(type: "reasoning.delta", payload: ["text": "streamed fragment"])
    await transport.event(type: "message.complete", payload: ["text": "answer", "reasoning": "canonical replacement"])
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
