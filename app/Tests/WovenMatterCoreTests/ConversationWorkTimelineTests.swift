import Testing
import WovenMatterCore

private func record(
  _ activity: AgentRunActivity,
  run: String = "run",
  at createdAt: String,
  sequence: Int64? = nil
) -> WorkspaceRunActivityRecord {
  WorkspaceRunActivityRecord(
    id: "\(activity.id)@\(createdAt)", runID: run, conversationID: "chat",
    activity: activity, createdAt: createdAt, sequence: sequence
  )
}

private func tool(_ id: String, _ name: String, status: String = "completed") -> AgentRunActivity {
  AgentRunActivity(id: id, kind: .tool, status: status, toolName: name)
}

private func groups(_ timeline: ConversationWorkTimeline) -> [ConversationWorkGroup] {
  timeline.entries.compactMap {
    if case .group(let group) = $0.content { group } else { nil }
  }
}

@Suite("Conversation work timeline")
struct ConversationWorkTimelineTests {

  @Test("completed reasoning does not hide a still-running tool label")
  func liveActivitySelection() {
    let command = AgentRunActivity(id: "command", kind: .tool, title: "Run the stream check", status: "running", toolName: "bash")
    let thought = AgentRunActivity(id: "thought", kind: .thought, status: "completed", content: "Checking the next step.")
    let group = ConversationWorkGroup(id: "group", activities: [command, thought], endsTimeline: true)
    #expect(group.liveActivity?.id == "command")
    #expect(group.liveLabel(runIsActive: true) == "Run the stream check")
    #expect(group.latestThought?.id == "thought")
    #expect(group.activeActivityIDs == ["command"])
  }

  @Test("waiting indicator covers commentary and failure without doubling active work")
  func thinkingIndicator() {
    #expect(ConversationWorkTimeline.empty.needsThinkingIndicator)
    let commentary = record(AgentRunActivity(id: "c", kind: .assistant, content: "Checking."), at: "1")
    #expect(ConversationWorkTimeline(records: [commentary], commentaryIDs: ["c"]).needsThinkingIndicator)
    let failed = record(tool("failed", "bash", status: "failed"), at: "2")
    #expect(ConversationWorkTimeline(records: [failed], commentaryIDs: []).needsThinkingIndicator)
    let running = record(tool("running", "bash", status: "running"), at: "3")
    #expect(!ConversationWorkTimeline(records: [failed, running], commentaryIDs: []).needsThinkingIndicator)
  }

  @Test("mixed groups summarize two categories and count the remainder")
  func mixedSummary() {
    let activities = [
      tool("1", "read"), tool("2", "bash"), tool("3", "grep"),
      tool("4", "bash"), tool("5", "WebSearch"), tool("6", "mystery"),
    ]
    let records = activities.enumerated().map { record($1, at: "\($0)") }
    let group = groups(ConversationWorkTimeline(records: records, commentaryIDs: []))[0]

    #expect(group.summary == "Read 1 file, ran 2 commands, and performed 3 other actions")
    #expect(group.action == nil)
  }

  @Test("only a status-less thought that ends the timeline is live; generic empty thoughts are hidden")
  func thoughtLiveness() {
    let thought = { (id: String) in AgentRunActivity(id: id, kind: .thought, phase: "start", content: "**\(id)**") }
    let records = [
      record(thought("t1"), at: "1"),
      record(tool("a", "bash"), at: "2"),
      record(AgentRunActivity(id: "generic", kind: .thought, title: "Thinking"), at: "3"),
      record(thought("t2"), at: "4"),
    ]
    let tail = groups(ConversationWorkTimeline(records: records, commentaryIDs: []))[0]
    #expect(tail.activities.map(\.id) == ["t1", "a", "t2"])
    #expect(tail.activeActivityIDs == ["t2"])
    #expect(tail.liveLabel(runIsActive: true) == "t2")

    let followed = ConversationWorkTimeline(records: records + [
      record(AgentRunActivity(id: "c", kind: .assistant, content: "Next"), at: "5"),
    ], commentaryIDs: ["c"])
    #expect(groups(followed)[0].activeActivityIDs.isEmpty)
  }

  @Test("edit groups count distinct files and lone thoughts use a meaningful label")
  func editsAndThoughts() {
    let edit = { (id: String, path: String) in
      AgentRunActivity(id: id, kind: .tool, status: "completed", toolName: "Edit",
        locations: [AgentRunLocation(path: path)])
    }
    let records = [
      record(edit("1", "a.swift"), at: "1"),
      record(edit("2", "a.swift"), at: "2"),
      record(edit("3", "b.swift"), at: "3"),
      record(AgentRunActivity(id: "p", kind: .progress, title: "Compacting"), at: "4"),
      record(AgentRunActivity(id: "t", kind: .thought, detail: "Weighing  the\noptions"), at: "5"),
      record(AgentRunActivity(id: "empty", kind: .thought, content: "  "), at: "6"),
    ]
    let all = groups(ConversationWorkTimeline(records: records, commentaryIDs: []))

    #expect(all[0].summary == "Changed 2 files")
    #expect(all[0].action == .edit)
    #expect(all[1].isThoughtOnly)
    #expect(all[1].summary == "Weighing the options")
    #expect(all[1].activities.map(\.id) == ["t"])
  }

  @Test("the latest segment stays before later visible work, even after a stop")
  func liveCommentaryPartition() {
    let segment = AgentRunActivity(id: "s", kind: .assistant, content: "Let me check.", assistantMessageID: "m")
    let records = [record(segment, at: "1"), record(tool("a", "bash", status: "running"), at: "2")]
    let activities = records.map(\.activity)
    let transcript = AssistantTranscriptProjection(messageID: "m", content: "Let me check.\n", activities: activities)

    let live = ConversationWorkTimeline.displayPartition(transcript, activities: activities, isLive: true)
    #expect(live.commentaryIDs == ["s"])
    #expect(live.body.allSatisfy { $0.isWhitespace })
    #expect(ConversationWorkTimeline(records: records, commentaryIDs: live.commentaryIDs).entries.map(\.id)
      == ["commentary:s", "group:a"])

    let settled = ConversationWorkTimeline.displayPartition(transcript, activities: activities, isLive: false)
    #expect(settled.commentaryIDs == ["s"])
    #expect(settled.body.allSatisfy { $0.isWhitespace })

    let unfollowed = ConversationWorkTimeline.displayPartition(transcript, activities: [segment], isLive: true)
    #expect(unfollowed.commentaryIDs.isEmpty)
    let checklistOnly = ConversationWorkTimeline.displayPartition(transcript,
      activities: [segment, AgentRunActivity(id: "p", kind: .plan, planKind: "checklist"),
        tool("update", "update_plan")], isLive: true)
    #expect(checklistOnly.commentaryIDs.isEmpty)
    #expect(checklistOnly.body == transcript.body)
  }

}
