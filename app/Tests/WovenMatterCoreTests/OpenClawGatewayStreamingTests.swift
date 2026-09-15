import Testing
@testable import WovenMatterClient
@testable import WovenMatterCore
@testable import WovenMatterDashboardStore

struct OpenClawGatewayStreamingTests {
  @Test func nativeProjectionPreservesWhitespaceTerminalTailAndStructuredActivity() throws {
    let whitespace = project("agent", [
      "runId": .string("run"), "stream": .string("assistant"),
      "data": .object(["delta": .string("  partial\n\t")]),
    ])
    #expect(whitespace?.assistantUpdate == .append("  partial\n\t"))

    let emptyTerminal = project("chat", [
      "runId": .string("run"), "state": .string("aborted"),
      "message": .object(["text": .string("")]),
    ])
    #expect(emptyTerminal?.assistantUpdate == nil)
    #expect(emptyTerminal?.terminalState == .cancelled(nil))

    let tool = project("session.tool", [
      "runId": .string("run"), "seq": .number(4),
      "data": .object([
        "phase": .string("result"), "toolCallId": .string("tool"),
        "name": .string("exec"), "result": .string("tail\n"),
      ]),
    ])
    #expect(tool?.eventType == "tool_result")
    #expect(tool?.activity?.content == "tail\n")

    let plan = project("agent", [
      "runId": .string("run"), "stream": .string("plan"),
      "data": .object(["steps": .array([
        .object(["step": .string("Validate"), "status": .string("in_progress")]),
      ])]),
    ])
    #expect(plan?.activity?.planEntries == [
      AgentRunPlanEntry(content: "Validate", status: "in_progress"),
    ])
  }

  @Test func gatewayFenceDropsReplayReportsGapsAndKeepsLateMetadata() {
    var fence = GatewayStreamEventFence()
    #expect(fence.evaluate(event("agent", stream: "assistant", seq: 1),
      remoteRunID: "run") == .accept)
    #expect(fence.evaluate(event("agent", stream: "assistant", seq: 1),
      remoteRunID: "run") == .duplicate)
    #expect(fence.evaluate(event("agent", stream: "assistant", seq: 3),
      remoteRunID: "run") == .gap)
    #expect(fence.evaluate(event("agent", stream: "reasoning", seq: 4),
      remoteRunID: "run") == .accept)
    #expect(fence.evaluate(event("agent", stream: "tool", seq: 3),
      remoteRunID: "run") == .accept)
    #expect(fence.evaluate(event("session.tool", seq: 5),
      remoteRunID: "run") == .gap)
  }

  @Test func assistantMirrorDedupKeepsRepeatedTextOnOwningSource() {
    var source = GatewayAssistantStreamSource()
    let first = source.accepts(event("agent"), runID: "run", update: .append("ha"), terminal: false)
    let repeated = source.accepts(event("agent"), runID: "run", update: .append("ha"), terminal: false)
    let mirrored = source.accepts(event("chat"), runID: "run", update: .append("ha"), terminal: false)
    let canonical = source.accepts(event("chat"), runID: "run", update: .replace("haha"), terminal: false)
    let staleAgent = source.accepts(event("agent"), runID: "run", update: .append("ha"), terminal: false)
    let terminal = source.accepts(event("chat"), runID: "run", update: .replace(""), terminal: true)
    let late = source.accepts(event("agent"), runID: "run", update: .append("late"), terminal: false)
    #expect(first)
    #expect(repeated)
    #expect(!mirrored)
    #expect(canonical)
    #expect(!staleAgent)
    #expect(terminal)
    #expect(!late)
  }

  @Test func canonicalHistoryRecoveryRetriesEmptyAndMatchesExactInput() async {
    let fixture = HistoryFixture()
    let result = await GatewayHistoryRecovery.assistantText(
      remoteRunID: "owned", knownInputIDs: ["owned"],
      fetch: { await fixture.fetch() }, pause: { _ in }
    )
    #expect(result == "Canonical final")
    #expect(await fixture.calls == 3)
  }

  @Test func lifecycleEndDoesNotFenceAuthoritativeChatFinal() {
    let lifecycle = project("agent", [
      "runId": .string("run"), "stream": .string("lifecycle"),
      "data": .object(["phase": .string("end")]),
    ])
    let final = project("chat", [
      "runId": .string("run"), "state": .string("final"),
      "message": .object(["text": .string("Canonical answer")]),
    ])
    #expect(lifecycle?.terminalState == nil)
    #expect(lifecycle?.activity?.status == "completed")
    #expect(final?.assistantUpdate == .replace("Canonical answer"))
    #expect(final?.terminalState == .completed)
  }

  @Test func nativeApprovalRequestUsesNestedRunOwnership() {
    let requested = project("exec.approval.requested", [
      "id": .string("approval"),
      "request": .object([
        "runId": .string("owned-run"),
        "sessionKey": .string("agent:fixture:session"),
        "command": .string("pwd"),
      ]),
    ])
    let resolved = project("exec.approval.resolved", [
      "id": .string("approval"), "runId": .string("owned-run"),
      "decision": .string("allow-once"),
    ])
    #expect(requested?.runID == "owned-run")
    #expect(requested?.approval?.id == resolved?.approval?.id)
    #expect(resolved?.runID == "owned-run")
  }

  private func project(
    _ name: String,
    _ payload: [String: GatewayJSONValue]
  ) -> OpenClawGatewayEventProjection? {
    OpenClawGatewayEventProjection.project(
      OpenClawGatewayEvent(name: name, payload: .object(payload), sequence: nil)
    )
  }

  private func event(
    _ name: String,
    stream: String? = nil,
    seq: Int? = nil
  ) -> OpenClawGatewayEvent {
    var payload: [String: GatewayJSONValue] = [:]
    if let stream { payload["stream"] = .string(stream) }
    if let seq { payload["seq"] = .number(Double(seq)) }
    return OpenClawGatewayEvent(name: name, payload: .object(payload), sequence: nil)
  }
}

private actor HistoryFixture {
  var calls = 0

  func fetch() -> GatewayJSONValue {
    calls += 1
    guard calls == 3 else {
      return .object(["messages": .array([.object([
        "role": .string("assistant"), "text": .string(""),
        "__openclaw": .object(["runId": .string("owned")]),
      ])])])
    }
    return .object(["messages": .array([
      .object([
        "role": .string("assistant"), "text": .string("Other"),
        "__openclaw": .object(["runId": .string("foreign")]),
      ]),
      .object([
        "role": .string("assistant"), "text": .string("Canonical final"),
        "__openclaw": .object(["runId": .string("owned")]),
      ]),
    ])])
  }
}
