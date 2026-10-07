import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct PiStreamingReviewTests {
  @Test func arbitraryExtensionTodoToolsRemainToolsWithoutAStandardChecklistContract() async throws {
    let fixture = PiPipeFixture()
    let names = ["todo", "todo_list", "todowrite", "update_plan", "update_checklist", "subagent"]
    let lines = try names.map { name in
      String(decoding: try JSONSerialization.data(withJSONObject: [
        "type": "tool_execution_end", "toolCallId": name, "toolName": name, "isError": false,
        "result": ["content": [["type": "text", "text": "{\"todos\":[]}"]]]
      ]), as: UTF8.self)
    }
    let server = Task { try await fixture.serve(settles: true, streamLines: lines) }
    try await fixture.initialize()
    let collector = PiStreamingReviewCollector()
    _ = try await fixture.client.prompt("fixture") { await collector.record($0) }
    try await server.value
    let activities = await collector.values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event else { return nil }; return activity
    }
    #expect(activities.map(\.kind) == Array(repeating: .tool, count: names.count))
    #expect(activities.map(\.toolName) == names)
    await fixture.client.shutdown()
  }

  @Test func authoritativeFinalRepairsDeltasAcrossToolBoundary() async throws {
    let fixture = PiPipeFixture()
    let lines = [
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"partial"}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"corrected"}],"stopReason":"toolUse"}}"#,
      #"{"type":"tool_execution_start","toolCallId":"call","toolName":"read","args":{"path":"fixture"}}"#,
      #"{"type":"tool_execution_update","toolCallId":"call","toolName":"read","args":{"path":"fixture"},"partialResult":{"content":[{"type":"text","text":"partial output"}]}}"#,
      #"{"type":"tool_execution_end","toolCallId":"call","toolName":"read","result":{"content":[{"type":"text","text":"final output"}]},"isError":false}"#,
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":" stale"}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":" final"}],"stopReason":"stop"}}"#,
    ]
    let server = Task { try await fixture.serve(settles: true, streamLines: lines) }
    try await fixture.initialize()
    let collector = PiStreamingReviewCollector()
    let reason = try await fixture.client.prompt("fixture") { await collector.record($0) }
    try await server.value
    #expect(reason == .endTurn)
    let events = await collector.values
    #expect(events.contains(.assistantSnapshot("corrected")))
    #expect(events.contains(.assistantSnapshot("corrected final")))
    #expect(events.filter { $0 == .assistantBoundary }.count == 2)
    let tools = events.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .tool else { return nil }
      return activity
    }
    #expect(tools.map(\.phase) == ["start", "update", "end"])
    #expect(tools.map(\.content) == [nil, "partial output", "final output"])
    #expect(tools[1].contentIsDelta == false)
    await fixture.client.shutdown()
  }

  @Test func thinkingIndicesStayDistinctAndRetryErrorIsSuperseded() async throws {
    let fixture = PiPipeFixture()
    let lines = [
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"retry me"}}"#,
      #"{"type":"agent_end","messages":[],"willRetry":true}"#,
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"one"}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"one"}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":1}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":1,"delta":"two"}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":1,"content":"two"}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"recovered"}],"stopReason":"stop"}}"#,
    ]
    let server = Task { try await fixture.serve(settles: true, streamLines: lines) }
    try await fixture.initialize()
    let collector = PiStreamingReviewCollector()
    let reason = try await fixture.client.prompt("fixture") { await collector.record($0) }
    try await server.value
    #expect(reason == .endTurn)
    let thoughts = await collector.values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .thought else { return nil }
      return activity
    }
    #expect(Set(thoughts.map(\.id)).count == 2)
    #expect(thoughts.filter { $0.phase == "start" }.count == 2)
    #expect(thoughts.filter { $0.phase == "end" }.map(\.content) == ["one", "two"])
    await fixture.client.shutdown()
  }

  @Test func finalErrorPublishesTailBeforeSettledFailure() async throws {
    let fixture = PiPipeFixture()
    let lines = [
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"useful tail"}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"useful tail"}],"stopReason":"error","errorMessage":"provider failed"}}"#,
    ]
    let server = Task { try await fixture.serve(settles: true, streamLines: lines) }
    try await fixture.initialize()
    let collector = PiStreamingReviewCollector()
    do {
      _ = try await fixture.client.prompt("fixture") { await collector.record($0) }
      Issue.record("Expected the settled provider error")
    } catch PiRPCClientError.commandFailed(let message) {
      #expect(message == "provider failed")
    }
    try await server.value
    let events = await collector.values
    #expect(events.contains(.assistantSnapshot("useful tail")))
    #expect(events.last == .assistantBoundary)
    await fixture.client.shutdown()
  }
}

private actor PiStreamingReviewCollector {
  private(set) var values: [LocalACPEvent] = []
  func record(_ event: LocalACPEvent) { values.append(event) }
}
