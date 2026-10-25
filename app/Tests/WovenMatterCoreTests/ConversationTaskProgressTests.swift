import Testing
import WovenMatterCore

private func plan(
  _ entries: [(String, String)],
  id: String = "plan",
  run: String = "run",
  phase: String = "update",
  at createdAt: String,
  content: String? = nil
) -> WorkspaceRunActivityRecord {
  WorkspaceRunActivityRecord(
    id: "\(run):\(id)@\(createdAt)", runID: run, conversationID: "chat",
    activity: AgentRunActivity(
      id: id, kind: .plan, phase: phase, content: content,
      planEntries: entries.map { AgentRunPlanEntry(content: $0.0, status: $0.1) }
    ),
    createdAt: createdAt
  )
}

@Suite("Conversation task progress")
struct ConversationTaskProgressTests {


  @Test("only the active run's latest checklist is selected, without stale fallback")
  func planSelection() {
    let old = plan([("Old", "pending")], run: "previous", at: "1")
    #expect(ConversationTaskProgress.latest(in: [old], activeRunID: "run") == nil)

    let records = [
      old,
      plan([("First", "completed")], id: "a", at: "2"),
      plan([("Second", "pending")], id: "b", at: "3"),
      plan([], id: "b", at: "4", content: "## Proposed plan"),
    ]
    #expect(ConversationTaskProgress.latest(in: records, activeRunID: "run")?.planID == "b")

    let cleared = records + [plan([], id: "b", phase: "clear", at: "5")]
    #expect(ConversationTaskProgress.latest(in: cleared, activeRunID: "run") == nil)

    let proposalOnly = [plan([], at: "1", content: "1. Investigate")]
    #expect(ConversationTaskProgress.latest(in: proposalOnly, activeRunID: "run") == nil)

    let allCancelled = [plan([("Skip", "canceled")], at: "1")]
    #expect(ConversationTaskProgress.latest(in: allCancelled, activeRunID: "run") == nil)
  }

}
