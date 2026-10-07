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
  @Test("commentary splits work groups that keep their first member's identity")
  func chronologicalGrouping() {
    let records = [
      record(AgentRunActivity(id: "t1", kind: .thought, content: "**Inspecting files**\nDetails"), at: "1"),
      record(tool("a", "bash", status: "running"), at: "2"),
      record(AgentRunActivity(id: "c1", kind: .assistant, content: "Found it."), at: "3"),
      record(AgentRunActivity(id: "final", kind: .assistant, content: "Done."), at: "4"),
      record(tool("b", "read"), at: "5"),
      record(AgentRunActivity(id: "fc", kind: .fileChange, changes: [.init(path: "a", newText: "x")]), at: "6"),
      record(tool("a", "bash"), at: "7"),
    ]
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: ["c1"])

    #expect(timeline.entries.map(\.id) == ["group:t1", "commentary:c1", "group:b"])
    let first = groups(timeline)[0]
    #expect(first.activities.map(\.id) == ["t1", "a"])
    #expect(first.activities[1].status == "completed")
    #expect(first.summary == "Ran 1 command")
    #expect(groups(timeline)[1].singleActivity?.id == "b")
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

  @Test("live labels follow the latest running call, then the latest settled one")
  func liveLabels() {
    let running = ConversationWorkGroup(id: "g", activities: [
      tool("1", "bash", status: "running"),
      AgentRunActivity(id: "2", kind: .thought, status: "completed", content: "x"),
    ])
    #expect(running.liveLabel(runIsActive: true) == "bash")
    #expect(running.hasActiveActivity)
    #expect(running.liveLabel(runIsActive: false) == nil)

    let settled = ConversationWorkGroup(id: "g", activities: [
      AgentRunActivity(id: "t", kind: .thought, status: "in_progress", content: "plain"),
    ])
    #expect(settled.liveLabel(runIsActive: true) == "Thinking")
  }

  @Test("clear removes an activity and a later update restores it from the clear")
  func clearRemoval() {
    let entries = [AgentRunPlanEntry(content: "Step", status: "pending")]
    let plan = { (phase: String, entries: [AgentRunPlanEntry]) in
      AgentRunActivity(id: "plan", kind: .plan, phase: phase, planEntries: entries)
    }
    let cleared = ConversationWorkTimeline(records: [
      record(plan("update", entries), at: "1"),
      record(plan("clear", []), at: "2"),
    ], commentaryIDs: [])
    #expect(cleared.entries.isEmpty)

    let restored = ConversationWorkTimeline(records: [
      record(plan("update", entries), at: "1"),
      record(plan("clear", []), at: "2"),
      record(AgentRunActivity(id: "plan", kind: .plan, phase: "update", title: "Plan"), at: "3"),
    ], commentaryIDs: [])
    guard case .activity(let activity)? = restored.entries.first?.content else {
      Issue.record("expected the restored plan")
      return
    }
    #expect(activity.planEntries.isEmpty)
  }

  @Test("deltas append and snapshots replace in precedes order")
  func deltaMerge() {
    let records = [
      record(AgentRunActivity(id: "c", kind: .assistant, content: "lo", contentIsDelta: true), at: "1", sequence: 2),
      record(AgentRunActivity(id: "c", kind: .assistant, content: "Hel", contentIsDelta: false), at: "1", sequence: 1),
    ]
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: ["c"])
    guard case .commentary(let activity)? = timeline.entries.first?.content else {
      Issue.record("expected commentary")
      return
    }
    #expect(activity.content == "Hello")
  }

  @Test("the fold keeps failed rows and failed calls visible")
  func foldedFailures() {
    let records = [
      record(tool("1", "bash"), at: "1"),
      record(tool("2", "bash", status: "failed"), at: "2"),
      record(AgentRunActivity(id: "c", kind: .assistant, content: "Next"), at: "3"),
      record(tool("3", "read"), at: "4"),
      record(AgentRunActivity(id: "x", kind: .activity, status: "error", content: "Lost"), at: "5"),
    ]
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: ["c"])

    #expect(groups(timeline)[0].hasFailure)
    #expect(timeline.foldedEntries.map(\.id) == ["failed:group:1", "activity:x"])
    guard case .group(let failed)? = timeline.foldedEntries.first?.content else {
      Issue.record("expected failed calls")
      return
    }
    #expect(failed.activities.map(\.id) == ["2"])
  }
}
