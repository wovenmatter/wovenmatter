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
    try database.settleCalendarRuns()
    var attempts = 0
    for run in try database.dueCalendarRuns(now: now) {
      try Task.checkCancellation()
      if isRunning(run.sessionID) { continue }
      guard hasCapacity(), attempts < 20 else { break }
      attempts += 1
      do {
        guard try database.isCalendarRunActive(run.id) else { continue }
        // Reapply saved settings on every attempt: the user may have changed
        // the session while this delivery was queued or the app was closed.
        try await prepare(run)
        try Task.checkCancellation()
        guard try database.isCalendarRunActive(run.id) else { continue }
        // Preparation awaits a native connection. The user may have started
        // another turn in the same session while we were waiting.
        guard !isRunning(run.sessionID), hasCapacity() else { continue }
        let delivery = try database.prepareCalendarDelivery(runID: run.id, now: now)
        try await dispatch(delivery)
      } catch is CancellationError {
        if Task.isCancelled { throw CancellationError() }
      } catch {
        try database.deferCalendarRun(run.id, error: error.localizedDescription, now: now)
      }
    }
    try database.settleCalendarRuns()
  }
}
