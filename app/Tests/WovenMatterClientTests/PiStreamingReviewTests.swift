import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct PiStreamingReviewTests {
  @Test func authoritativeFinalRepairsDeltasAcrossToolBoundary() async throws {
    let fixture = PiStreamingReviewFixture()
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
    let server = Task { try await fixture.serve(lines: lines) }
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
    let fixture = PiStreamingReviewFixture()
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
    let server = Task { try await fixture.serve(lines: lines) }
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
    let fixture = PiStreamingReviewFixture()
    let lines = [
      #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
      #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"useful tail"}}"#,
      #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"useful tail"}],"stopReason":"error","errorMessage":"provider failed"}}"#,
    ]
    let server = Task { try await fixture.serve(lines: lines) }
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

private struct PiStreamingReviewFixture: Sendable {
  let commands = Pipe()
  let events = Pipe()
  let client: PiRPCClient

  init() {
    client = PiRPCClient(
      launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .pi,
        executableURL: URL(filePath: "/nonexistent-review-pi"), arguments: []),
      workingDirectory: URL(filePath: "/private/tmp"),
      input: commands.fileHandleForWriting, output: events.fileHandleForReading
    )
  }

  func initialize() async throws {
    _ = try await client.initializeSession(workingDirectory: URL(filePath: "/private/tmp"),
      existingSessionID: nil, title: nil, systemPrompt: nil)
  }

  func serve(lines: [String]) async throws {
    defer { try? events.fileHandleForWriting.close() }
    let reader = PiStreamingReviewCommandReader(handle: commands.fileHandleForReading)
    while let line = try await reader.next() {
      let command = try JSONSerialization.jsonObject(with: line) as! [String: Any]
      let type = command["type"] as? String
      let data: [String: Any] = type == "get_state"
        ? ["sessionId": "review-session"] : [:]
      var bytes = try JSONSerialization.data(withJSONObject: [
        "type": "response", "id": command["id"]!, "success": true, "data": data,
      ])
      bytes.append(0x0A)
      try events.fileHandleForWriting.write(contentsOf: bytes)
      if type == "prompt" {
        for event in lines {
          try events.fileHandleForWriting.write(contentsOf: Data("\(event)\n".utf8))
        }
        try events.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"agent_settled\"}\n".utf8))
        return
      }
    }
  }
}

private struct PiStreamingReviewCommandReader: Sendable {
  let handle: FileHandle
  func next() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          var data = Data()
          while true {
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
              continuation.resume(returning: data.isEmpty ? nil : data); return
            }
            if byte[0] == 0x0A { continuation.resume(returning: data); return }
            data.append(byte)
          }
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
