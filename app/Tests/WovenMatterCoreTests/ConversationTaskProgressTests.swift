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
  @Test("status aliases normalize and cancelled steps are not counted")
  func statusAliases() throws {
    let progress = try #require(ConversationTaskProgress.latest(in: [
      plan([
        ("Read", "done"), ("Plan", "Completed"), ("Build", "inProgress"),
        ("Test", "in_progress"), ("Ship", "todo"), ("Drop", "cancelled"),
      ], at: "1"),
    ], activeRunID: "run"))

    #expect(progress.steps.map(\.status) == [.completed, .completed, .inProgress, .inProgress, .pending])
    #expect(progress.allSteps.last?.status == .cancelled)
    #expect(progress.completedCount == 2)
    #expect(progress.totalCount == 5)
    #expect(progress.currentStep.label == "Build")
  }

  @Test("current step prefers running, then pending, then the last step")
  func currentStep() throws {
    let pending = try #require(ConversationTaskProgress.latest(in: [
      plan([("A", "completed"), ("B", "pending"), ("C", "pending")], at: "1"),
    ], activeRunID: "run"))
    #expect(pending.currentStep.label == "B")

    let finished = try #require(ConversationTaskProgress.latest(in: [
      plan([("A", "completed"), ("B", "completed")], at: "1"),
    ], activeRunID: "run"))
    #expect(finished.currentStep.label == "B")
    #expect(finished.isComplete)
  }

  @Test("duplicate labels keep unique occurrence IDs")
  func duplicateLabels() throws {
    let progress = try #require(ConversationTaskProgress.latest(in: [
      plan([("Run tests", "completed"), ("Fix", "completed"), ("Run tests", "pending")], at: "1"),
    ], activeRunID: "run"))

    #expect(Set(progress.steps.map(\.id)).count == 3)
    #expect(progress.currentStep.id == progress.steps[2].id)
  }

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

  @Test("a plan marked as a proposal on any update is not a checklist")
  func proposalMarkedLater() {
    let steps = plan([("Investigate", "pending")], at: "1")
    let marked = WorkspaceRunActivityRecord(
      id: "run:plan@2", runID: "run", conversationID: "chat",
      activity: AgentRunActivity(id: "plan", kind: .plan, phase: "update", planKind: "proposal"),
      createdAt: "2"
    )
    #expect(ConversationTaskProgress.latest(in: [steps, marked], activeRunID: "run") == nil)
    #expect(ConversationTaskProgress.checklist(steps.activity.merging(marked.activity), runID: "run") == nil)
    #expect(ConversationTaskProgress.checklist(steps.activity, runID: "run")?.totalCount == 1)
  }
}
