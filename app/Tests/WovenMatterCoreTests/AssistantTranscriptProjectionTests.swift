import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Assistant transcript projection")
struct AssistantTranscriptProjectionTests {
  private func segment(_ id: String, _ text: String, prefix: String) -> AgentRunActivity {
    AgentRunActivity(id: id, kind: .assistant, content: text,
      assistantMessageID: "reply", assistantCheckpoint: AssistantTextCheckpoint(prefix))
  }

  @Test("late reasoning and tools never hide the latest answer")
  func lateWork() {
    let first = "Checking…\n"
    let answer = "```swift\n  let café = 1\n```\n"
    let activities = [segment("one", first, prefix: first),
      AgentRunActivity(id: "tool", kind: .tool),
      segment("two", answer, prefix: first + answer),
      AgentRunActivity(id: "late-thought", kind: .thought, content: "Late reasoning"),
      AgentRunActivity(id: "late-tool", kind: .tool)]
    let projection = AssistantTranscriptProjection(messageID: "reply", content: first + answer, activities: activities)
    #expect(projection.body == answer)
    #expect(projection.commentary.map(\.id) == ["one"])
    let whitespaceTail = AssistantTranscriptProjection(messageID: "reply", content: first + answer + "  ", activities: activities)
    #expect(whitespaceTail.body == answer + "  ")
  }

  @Test("same text segments remain distinct and partial tails stay outside work")
  func repeatedTextAndPartialTail() {
    let text = "Again.\n"
    let activities = [segment("one", text, prefix: text), segment("two", text, prefix: text + text)]
    let projection = AssistantTranscriptProjection(messageID: "reply", content: text + text + "  partial", activities: activities)
    #expect(projection.body == "  partial")
    #expect(projection.commentary.map(\.id) == ["one", "two"])
  }

  @Test("canonical replacement and unrelated steering reply keep complete text")
  func replacement() {
    let activities = [segment("one", "old", prefix: "old")]
    #expect(AssistantTranscriptProjection(messageID: "reply", content: "new", activities: activities).body == "new")
    #expect(AssistantTranscriptProjection(messageID: "reply", content: "new", activities: activities).commentary.isEmpty)
    #expect(AssistantTranscriptProjection(messageID: "steered", content: "old", activities: activities).body == "old")
    #expect(AssistantTextCheckpoint("é\n").followingText(in: "é\n tail") == " tail")
    #expect(AssistantTextCheckpoint("é\n").followingText(in: "e\n tail") == nil)
  }

  @Test("boundaries and updates preserve insertion order across reopen")
  func durableBoundaries() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let database = try WorkspaceDatabase(url: url)
    let conversation = try database.createLocalACPSession(runtimeKind: .codex, title: "Streaming", ownerDeviceID: UUID())
    let run = try database.beginLocalACPRun(conversationID: conversation, content: "Hello")
    let instant = Date(timeIntervalSince1970: 100)
    try database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "  First\n")
    try database.recordAssistantStreamBoundary(runID: run.runID, updatedAt: instant)
    try database.recordAssistantStreamBoundary(runID: run.runID, updatedAt: instant)
    try database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "z", kind: .tool, status: "running"), updatedAt: instant)
    try database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "a", kind: .thought, content: "Reasoning"), updatedAt: instant)
    try database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "z", kind: .tool, status: "completed"), updatedAt: instant)
    try database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Final\n")
    let page = try database.conversationHistoryPage(id: conversation, limit: 20)
    #expect(page.activities.map(\.activity.kind) == [.assistant, .tool, .thought])
    #expect(page.activities[1].activity.status == "completed")
    let reply = try #require(page.messages.first { $0.role == "assistant" })
    #expect(AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity)).body == "Final\n")
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try reopened.conversationHistoryPage(id: conversation, limit: 20) == page)
  }

  @Test("OpenCode canonical replacement removes obsolete work and restores part order")
  func nativeCanonicalParts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let database = try WorkspaceDatabase(url: url)
    let conversation = try database.createLocalACPSession(runtimeKind: .opencode, title: "Native",
      ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "native"))
    let first: OpenCodeValue = ["id": "text-one", "type": "text", "text": "Checking"]
    let final: OpenCodeValue = ["id": "text-two", "type": "text", "text": "  Final\n"]
    let tool: OpenCodeValue = ["id": "tool", "type": "tool", "name": "read",
      "state": ["status": "completed", "output": "Old output"]]
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.messages = [["id": "reply", "type": "assistant", "time": ["created": .number(1000), "completed": .number(2000)],
      "content": .array([first, tool, final])]]
    try database.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    var page = try database.conversationHistoryPage(id: conversation, limit: 20)
    #expect(page.activities.map(\.activity.kind) == [.assistant, .tool, .assistant])
    let reply = try #require(page.messages.first)
    #expect(AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity)).body == "  Final\n")
    // A canonical replacement reorders existing identities and removes a tool.
    snapshot.messages[0]["content"] = .array([final, first])
    try database.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    page = try database.conversationHistoryPage(id: conversation, limit: 20)
    #expect(page.activities.map(\.activity.id) == ["reply:text-two", "reply:text-one"])
    #expect(!page.activities.contains { $0.activity.kind == .tool })
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try reopened.conversationHistoryPage(id: conversation, limit: 20) == page)
  }


  @Test("trace events remain interleaved with persisted activity")
  func traceInterleaving() {
    let earlyTrace = WorkspaceRunActivityRecord(id: "trace", runID: "run", conversationID: "chat",
      activity: AgentRunActivity(id: "trace", kind: .thought), createdAt: "1")
    let laterActivity = WorkspaceRunActivityRecord(id: "activity", runID: "run", conversationID: "chat",
      activity: AgentRunActivity(id: "activity", kind: .tool), createdAt: "2", sequence: 1)
    #expect([laterActivity, earlyTrace].sorted(by: WorkspaceRunActivityRecord.precedes).map(\.id) == ["trace", "activity"])
  }


  @Test("final-only Gateway history preserves commentary without a full history sync", arguments: [false, true])
  func finalSegmentHistory(finalBoundary: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let conversation = try database.createLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let run = try database.beginLocalACPRun(conversationID: conversation, content: "Start")
    let commentary = "Checking…\n\n"
    try database.appendLocalACPAssistantChunk(runID: run.runID, chunk: commentary)
    try database.recordAssistantStreamBoundary(runID: run.runID)
    try database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "tool", kind: .tool))
    if finalBoundary {
      try database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Draft final")
      try database.recordAssistantStreamBoundary(runID: run.runID, finalSegment: true)
      try database.upsertDeviceOwnedRunActivity(runID: run.runID,
        activity: AgentRunActivity(id: "late-reasoning", kind: .thought, content: "Late reasoning"))
    }
    // No full session-history synchronization occurs: this reply is the only
    // history repair available, and its delivery can be replayed.
    for _ in 0..<2 {
      try database.replaceLocalACPAssistantMessage(runID: run.runID,
        assistantMessageID: run.assistantMessageID, content: "Final answer",
        preservingStreamCommentary: true)
      let page = try database.conversationHistoryPage(id: conversation, limit: 20)
      let reply = try #require(page.messages.first { $0.role == "assistant" })
      let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
        activities: page.activities.map(\.activity))
      #expect(reply.content == commentary + "Final answer")
      #expect(projection.body == "Final answer")
      #expect(projection.commentary.map(\.content) == [commentary])
    }
    // Whole-message snapshots retain their authoritative replacement contract.
    try database.replaceLocalACPAssistantMessage(runID: run.runID,
      assistantMessageID: run.assistantMessageID, content: "Replacement")
    let page = try database.conversationHistoryPage(id: conversation, limit: 20)
    let reply = try #require(page.messages.first { $0.role == "assistant" })
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity))
    #expect(projection.body == "Replacement")
    #expect(projection.commentary.isEmpty)
  }

}
