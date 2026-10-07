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

  /// The latest checklist belonging to `activeRunID`, or nil when that run has
  /// none or its latest checklist update cleared it.
  public static func latest(in records: [WorkspaceRunActivityRecord], activeRunID: String) -> Self? {
    var merged: [String: AgentRunActivity] = [:]
    var latestID: String?
    for record in records.lazy.filter({ $0.runID == activeRunID && $0.activity.kind == .plan && $0.activity.planKind != "proposal" })
      .sorted(by: { left, right in
        if let a = left.activity.detailVersion, let b = right.activity.detailVersion, a != b { return a < b }
        return WorkspaceRunActivityRecord.precedes(left, right)
      }) {
      let update = record.activity
      merged[update.id] = merged[update.id].map { $0.merging(update) } ?? update
      // Content-only updates, such as a proposed Markdown plan, are not
      // checklist updates and do not select their plan.
      if update.phase == "clear" || !update.planEntries.isEmpty { latestID = update.id }
    }
    guard let latestID, let plan = merged[latestID], plan.phase != "clear" else { return nil }
    return Self(runID: activeRunID, planID: latestID, entries: plan.planEntries)
  }
}
