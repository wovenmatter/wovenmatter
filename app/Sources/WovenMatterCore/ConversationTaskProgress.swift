import Foundation

/// Checklist progress for the composer's Tasks badge.
///
/// Built only from the active run's latest checklist update. A cleared plan
/// never falls back to an older plan or run, and a proposed Markdown plan
/// without entries is not a checklist. No timings are inferred.
public struct ConversationTaskProgress: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case pending
    case inProgress
    case completed
    /// Cancelled or skipped; retained in `allSteps` but excluded from counts.
    case cancelled

    public init(_ value: String) {
      let normalized = value.lowercased().filter { $0.isLetter }
      switch normalized {
      case "inprogress", "running", "active", "started", "doing", "working":
        self = .inProgress
      case "completed", "complete", "done", "finished", "succeeded", "success":
        self = .completed
      case "cancelled", "canceled", "skipped", "aborted":
        self = .cancelled
      default:
        self = .pending
      }
    }
  }

  public struct Step: Equatable, Identifiable, Sendable {
    /// Label plus occurrence, unique even when labels repeat.
    public let id: String
    public let label: String
    public let status: Status
  }

  public let runID: String
  public let planID: String
  /// Every source entry in order, including cancelled ones.
  public let allSteps: [Step]
  /// Counted entries: everything except cancelled steps.
  public let steps: [Step]
  public let completedCount: Int
  public var totalCount: Int { steps.count }
  /// The running step, else the first pending step, else the last step.
  public let currentStep: Step
  public var isComplete: Bool { completedCount == totalCount }

  public init?(runID: String, planID: String, entries: [AgentRunPlanEntry]) {
    var occurrences: [String: Int] = [:]
    let allSteps = entries.map { entry in
      let occurrence = occurrences[entry.content, default: 0]
      occurrences[entry.content] = occurrence + 1
      return Step(id: entry.nativeID ?? "\(entry.content)#\(occurrence)", label: entry.content, status: Status(entry.status))
    }
    let steps = allSteps.filter { $0.status != .cancelled }
    guard let current = steps.first(where: { $0.status == .inProgress })
      ?? steps.first(where: { $0.status == .pending })
      ?? steps.last else { return nil }
    self.runID = runID
    self.planID = planID
    self.allSteps = allSteps
    self.steps = steps
    completedCount = steps.filter { $0.status == .completed }.count
    currentStep = current
  }

  /// The checklist a merged plan activity shows, shared by the Tasks badge and
  /// the inline transcript. A proposed or cleared plan is not a checklist.
  public static func checklist(_ plan: AgentRunActivity, runID: String) -> Self? {
    guard plan.kind == .plan, plan.planKind != "proposal", plan.phase != "clear" else { return nil }
    return Self(runID: runID, planID: plan.id, entries: plan.planEntries)
  }

  /// The latest checklist belonging to `activeRunID`, or nil when that run has
  /// none or its latest checklist update cleared it.
  public static func latest(in records: [WorkspaceRunActivityRecord], activeRunID: String) -> Self? {
    var merged: [String: AgentRunActivity] = [:]
    var latestID: String?
    for record in records.lazy.filter({ $0.runID == activeRunID && $0.activity.kind == .plan })
      .sorted(by: { left, right in
        let a = left.activity.detailVersion ?? Int64.min
        let b = right.activity.detailVersion ?? Int64.min
        if a != b { return a < b }
        return WorkspaceRunActivityRecord.precedes(left, right)
      }) {
      let update = record.activity
      let plan = merged[update.id].map { $0.merging(update) } ?? update
      merged[update.id] = plan
      // A proposal (marked on any of its updates) and content-only updates,
      // such as a proposed Markdown plan, are not checklist updates and do
      // not select their plan.
      guard plan.planKind != "proposal" else { continue }
      if update.phase == "clear" || !update.planEntries.isEmpty { latestID = update.id }
    }
    return latestID.flatMap { merged[$0] }.flatMap { checklist($0, runID: activeRunID) }
  }
}
