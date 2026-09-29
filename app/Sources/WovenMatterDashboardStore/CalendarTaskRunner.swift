import Foundation
import WovenMatterCore

/// One app-owned scheduler pass. The app supplies its ordinary session launch
/// and dispatch operations; tests can exercise scheduling without provider calls.
@MainActor
public enum CalendarTaskRunner {
  public static func tick(database: WorkspaceDatabase, now: Date = Date(),
      isRunning: (String) -> Bool, hasCapacity: () -> Bool,
      prepare: (WorkspaceCalendarRun) async throws -> Void,
      dispatch: (WorkspaceSessionDelivery) async throws -> Void) async throws {
    try await tick(database: database, now: now, isRunning: isRunning, hasCapacity: hasCapacity,
      beginPreparation: { _ in AgentDispatchFence() }, finishPreparation: { _ in },
      finishAttempt: { _, _ in }, prepare: { run, _ in try await prepare(run) },
      dispatch: { delivery, _ in try await dispatch(delivery) })
  }

  public static func tick(database: WorkspaceDatabase, now: Date = Date(),
      isRunning: (String) -> Bool, hasCapacity: () -> Bool,
      beginPreparation: (WorkspaceCalendarRun) throws -> AgentDispatchFence,
      finishPreparation: (WorkspaceCalendarRun) -> Void,
      finishAttempt: (WorkspaceCalendarRun, AgentDispatchFence) -> Void,
      prepare: (WorkspaceCalendarRun, AgentDispatchFence) async throws -> Void,
      dispatch: (WorkspaceSessionDelivery, AgentDispatchFence) async throws -> Void) async throws {
    try await database.settleCalendarRuns()
    var attempts = 0
    for run in try await database.dueCalendarRuns(now: now) {
      try Task.checkCancellation()
      if isRunning(run.sessionID) { continue }
      guard hasCapacity(), attempts < 20 else { break }
      attempts += 1
      var fence: AgentDispatchFence?
      var preparing = false
      defer {
        if preparing { finishPreparation(run) }
        if let fence { finishAttempt(run, fence) }
      }
      do {
        // Reserve this known destination and register Stop before the first
        // per-occurrence suspension, including database authorization reads.
        let admitted = try beginPreparation(run)
        fence = admitted
        preparing = true
        try admitted.check()
        let active = try await database.isCalendarRunActive(run.id)
        try admitted.check()
        guard active else { continue }
        // Reapply saved settings on every attempt: the user may have changed
        // the session while this delivery was queued or the app was closed.
        try await prepare(run, admitted)
        try admitted.check()
        let stillActive = try await database.isCalendarRunActive(run.id)
        try admitted.check()
        guard stillActive else { continue }
        guard !isRunning(run.sessionID), hasCapacity() else { continue }
        let delivery = try await database.prepareCalendarDelivery(runID: run.id, now: now)
        try admitted.check()
        // Canonical dispatch takes over the same admission lane. Keep the Stop
        // fence registered until dispatch finishes, but release preparation once.
        finishPreparation(run)
        preparing = false
        try await dispatch(delivery, admitted)
        if admitted.isCancelled && !admitted.hasDispatched {
          try await database.cancelCalendarRunBeforeDispatch(run.id)
        }
      } catch is CancellationError {
        if let fence, fence.isCancelled, !fence.hasDispatched {
          try await database.cancelCalendarRunBeforeDispatch(run.id)
        }
        if Task.isCancelled { throw CancellationError() }
      } catch {
        if let fence, fence.isCancelled, !fence.hasDispatched {
          try await database.cancelCalendarRunBeforeDispatch(run.id)
        } else {
          try await database.deferCalendarRun(run.id, error: error.localizedDescription, now: now)
        }
      }
    }
    try await database.settleCalendarRuns()
  }
}
