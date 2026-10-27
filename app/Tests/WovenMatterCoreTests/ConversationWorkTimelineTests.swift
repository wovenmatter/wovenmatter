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

  @Test("browser and computer work retain their action category")
  func browserAndComputerActions() {
    for name in ["woven_browser", "woven_browser_use", "browser_navigate"] {
      #expect(ConversationToolAction(tool("browser", name)) == .browser)
    }
    #expect(ConversationToolAction(tool("computer", "woven_computer_use")) == .computer)
    #expect(ConversationToolAction(tool("fetch", "web_fetch")) == .webFetch)
    let group = ConversationWorkGroup(id: "work", activities: [
      tool("browser", "woven_browser_use"), tool("computer", "woven_computer_use")
    ], endsTimeline: true)
    #expect(group.summary == "Used the browser 1 time and used the computer 1 time")
    #expect(ConversationToolAction.browser.summary(count: 2) == "Used the browser 2 times")
  }

  @Test("Pi ACP categories retain actual tool actions and meaningful live labels")
  func piACPToolPresentation() {
    // Shapes observed in the first live Pi run: category in toolName, actual
    // function in title, structured arguments in rawInputJSON. Values are synthetic.
    let cases: [(String, String, String, ConversationToolAction, String)] = [
      ("other", "web_search", #"{"query":"native stream ordering"}"#, .webSearch, "Searching the web: native stream ordering"),
      ("other", "woven_browser_use", #"{"action":"open","url":"https://example.com/private?token=hidden"}"#, .browser, "Browser: open example.com"),
      ("execute", "bash", #"{"command":"curl -H 'Authorization: hidden' https://example.com"}"#, .command, "Running curl"),
    ]
    for (category, title, input, expectedAction, label) in cases {
      let activity = AgentRunActivity(id: title, kind: .tool, title: title, status: "running",
        toolName: category, rawInputJSON: input)
      #expect(ConversationToolAction(activity) == expectedAction)
      #expect(activity.workTimelineLabel(active: true) == label)
      #expect(!activity.workTimelineLabel(active: true).contains("hidden"))
    }
    for program in ["pwd", "ls"] {
      let activity = AgentRunActivity(id: program, kind: .tool, title: program,
        status: "running", toolName: "execute")
      #expect(ConversationToolAction(activity) == .command)
      #expect(activity.workTimelineLabel(active: true) == "Running " + program)
      #expect(ConversationWorkGroup(id: program, activities: [activity]).summary == "Ran 1 command")
    }
    let failedThenThought = ConversationWorkTimeline(records: [
      record(AgentRunActivity(id: "failed", kind: .tool, title: "pwd", status: "failed", toolName: "execute"), at: "1"),
      record(AgentRunActivity(id: "thought", kind: .thought, status: "completed", content: "A supplied explanation."), at: "2"),
    ], commentaryIDs: [])
    #expect(failedThenThought.entries.map(\.id) == ["group:failed", "activity:thought"])
    #expect(groups(failedThenThought).first?.hasFailure == true)
    let generic = AgentRunActivity(id: "generic", kind: .tool, title: "Use tool", status: "running", toolName: "web_search")
    #expect(generic.workTimelineLabel(active: true) == "Searching the web")
    let snapshot = ConversationWorkGroup(id: "pi", activities: [
      AgentRunActivity(id: "search", kind: .tool, title: "web_search", status: "failed", toolName: "other"),
      AgentRunActivity(id: "browser", kind: .tool, title: "woven_browser_use", status: "completed", toolName: "other"),
    ])
    #expect(snapshot.summary == "Searched the web 1 time and used the browser 1 time")
    #expect(!snapshot.hasFailure, "A failed search must not mark a later successful browser call failed")
  }

  @Test("completed reasoning does not hide a still-running tool label")
  func liveActivitySelection() {
    let command = AgentRunActivity(id: "command", kind: .tool, title: "Run the stream check", status: "running", toolName: "bash")
    let thought = AgentRunActivity(id: "thought", kind: .thought, status: "completed", content: "Checking the next step.")
    let timeline = ConversationWorkTimeline(records: [record(command, at: "1"), record(thought, at: "2")], commentaryIDs: [])
    #expect(timeline.entries.map(\.id) == ["group:command", "activity:thought"])
    let group = groups(timeline)[0]
    #expect(group.liveActivity?.id == "command")
    #expect(group.liveLabel(runIsActive: true) == "Run the stream check")
    #expect(group.latestThought == nil, "Supplied reasoning must never be hidden in a tool group")
    #expect(group.activeActivityIDs == ["command"])
  }

  @Test("waiting indicator covers commentary and failure without doubling active work")
  func thinkingIndicator() {
    #expect(ConversationWorkTimeline.empty.needsThinkingIndicator)
    let commentary = record(AgentRunActivity(id: "c", kind: .assistant, content: "Checking."), at: "1")
    #expect(ConversationWorkTimeline(records: [commentary], commentaryIDs: ["c"]).needsThinkingIndicator)
    let failed = record(tool("failed", "bash", status: "failed"), at: "2")
    #expect(ConversationWorkTimeline(records: [failed], commentaryIDs: []).needsThinkingIndicator)
    let resumedThought = record(AgentRunActivity(id: "next-thought", kind: .thought,
      status: "completed", content: "A supplied thought after the failed call."), at: "4")
    let resumed = ConversationWorkTimeline(records: [failed, resumedThought], commentaryIDs: [])
    #expect(!resumed.needsThinkingIndicator, "A prior tool failure must not add generic Thinking after a supplied thought")
    #expect(resumed.entries.last?.id == "activity:next-thought")
    let running = record(tool("running", "bash", status: "running"), at: "3")
    #expect(!ConversationWorkTimeline(records: [failed, running], commentaryIDs: []).needsThinkingIndicator)
    let completed = record(tool("completed", "bash"), at: "4")
    #expect(ConversationWorkTimeline(records: [completed], commentaryIDs: []).needsThinkingIndicator,
      "Settled tools need a quiet waiting label until the next supplied event arrives")
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

  @Test("nonempty thoughts stand alone and empty text does not split consecutive tools")
  func standaloneThoughts() {
    let thought = { (id: String) in AgentRunActivity(id: id, kind: .thought, phase: "start", content: "**\(id)**") }
    let records = [
      record(thought("t1"), at: "1"),
      record(tool("a", "bash"), at: "2"),
      record(AgentRunActivity(id: "generic", kind: .thought, title: "Thinking", content: "  "), at: "3"),
      record(AgentRunActivity(id: "empty-commentary", kind: .assistant, content: " \n "), at: "3b"),
      record(tool("b", "read"), at: "4"),
      record(thought("t2"), at: "5"),
      record(AgentRunActivity(id: "generic", kind: .thought, status: "running",
        content: "\n", contentIsDelta: true), at: "6"),
    ]
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: ["empty-commentary"])
    #expect(timeline.entries.map(\.id) == ["activity:t1", "group:a", "activity:t2"])
    #expect(groups(timeline).map { $0.activities.map(\.id) } == [["a", "b"]])
    #expect(timeline.foldedEntries.map(\.id) == ["activity:t1", "activity:t2"])
  }

  @Test("thought phases preserve tool row identities across deltas and status revisions")
  func thoughtPhasesAndRevisions() throws {
    let activities = [
      tool("tool1", "read", status: "running"),
      tool("tool2", "bash", status: "running"),
      AgentRunActivity(id: "thoughtA", kind: .thought, status: "running", content: "Plan A."),
      tool("tool3", "web_search", status: "running"),
      tool("tool4", "woven_browser_use", status: "running"),
      AgentRunActivity(id: "thoughtB", kind: .thought, status: "running", content: "Plan B."),
    ]
    let records = activities.enumerated().map { record($1, at: "event-\($0)", sequence: Int64($0)) }
    let initial = ConversationWorkTimeline(records: Array(records.prefix(2)), commentaryIDs: [])
    #expect(initial.entries.map(\.id) == ["group:tool1"])
    #expect(groups(initial)[0].activities.map(\.id) == ["tool1", "tool2"])
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: [])
    let expectedIDs = ["group:tool1", "activity:thoughtA", "group:tool3", "activity:thoughtB"]
    #expect(timeline.entries.map(\.id) == expectedIDs)
    #expect(groups(timeline).map { $0.activities.map(\.id) } == [["tool1", "tool2"], ["tool3", "tool4"]])
    let updates = [
      AgentRunActivity(id: "tool2", kind: .tool, status: "completed", content: "Command result."),
      AgentRunActivity(id: "thoughtA", kind: .thought, status: "completed", content: " More context.", contentIsDelta: true),
      AgentRunActivity(id: "tool1", kind: .tool, status: "completed"),
      AgentRunActivity(id: "tool3", kind: .tool, status: "completed"),
      AgentRunActivity(id: "tool4", kind: .tool, status: "completed"),
      AgentRunActivity(id: "thoughtB", kind: .thought, status: "completed"),
    ].enumerated().map { record($1, at: "revision-\($0)", sequence: Int64(activities.count + $0)) }
    let settled = ConversationWorkTimeline(records: records + updates, commentaryIDs: [])
    #expect(settled.entries.map(\.id) == expectedIDs)
    #expect(groups(settled).map { $0.activities.map(\.id) } == [["tool1", "tool2"], ["tool3", "tool4"]])
    #expect(groups(settled).allSatisfy { $0.activities.allSatisfy { $0.kind == .tool && $0.status == "completed" } })
    guard case .activity(let thoughtA) = settled.entries[1].content else { Issue.record("Thought A was grouped"); return }
    #expect(thoughtA.content == "Plan A. More context.")
    #expect(thoughtA.status == "completed")
    #expect(settled.foldedEntries.map(\.id) == ["activity:thoughtA", "activity:thoughtB"])
  }

  @Test("commentary progress and subagent snapshots remain boundaries between tool lists")
  func commentaryAndSubagentBoundaries() throws {
    let subagents = try #require(AgentRunActivity.builtInSubagentSnapshot(
      rawPayloadJSON: #"{"subagents":[{"id":"child","name":"Reviewer","state":"running"}]}"#))
    let activities = [
      tool("tool1", "read"), tool("tool2", "bash"),
      AgentRunActivity(id: "comment", kind: .assistant, content: "Checking the next result."),
      tool("tool3", "read"),
      AgentRunActivity(id: "progress", kind: .progress, title: "Compacting", status: "completed"),
      tool("tool4", "bash"), subagents, tool("tool5", "web_search"),
      AgentRunActivity(id: "thought", kind: .thought, status: "completed", content: "Final supplied reasoning."),
    ]
    let records = activities.enumerated().map { record($1, at: "event-\($0)", sequence: Int64($0)) }
    let timeline = ConversationWorkTimeline(records: records, commentaryIDs: ["comment"])
    #expect(timeline.entries.map(\.id) == ["group:tool1", "commentary:comment", "group:tool3",
      "activity:progress", "group:tool4", "activity:built-in-subagents", "group:tool5", "activity:thought"])
    #expect(groups(timeline).map { $0.activities.map(\.id) } == [["tool1", "tool2"], ["tool3"], ["tool4"], ["tool5"]])
    #expect(timeline.foldedEntries.map(\.id) == ["commentary:comment", "activity:thought"])
    guard case .activity(let snapshot) = timeline.entries[5].content else { Issue.record("Subagent snapshot was grouped"); return }
    #expect(snapshot.subagents?.map(\.id) == ["child"])
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
