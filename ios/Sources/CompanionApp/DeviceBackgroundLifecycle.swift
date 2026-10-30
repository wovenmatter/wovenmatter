import Foundation
import PiDurableRuntime
import UIKit
import WovenMatterCompanion

extension CompanionModel {
  @discardableResult
  func beginDeviceExecutionAttempt(_ id: String, runID: String, runtime: PiDurableRuntime, userInitiated: Bool) -> String {
    let attemptID = UUID().uuidString
    localExecutionAttempts[id] = attemptID
    // Quick Chat uses only the short save/interruption allowance. It never
    // requests continued processing or promises background agent execution.
    beginFallbackExecutionBackgroundTask()
    return attemptID
  }

  func finishDeviceExecutionAttempt(_ id: String, runID: String, attemptID: String?, success: Bool) {
    if let attemptID, localExecutionAttempts[id] != attemptID { return }
    localExecutionAttempts.removeValue(forKey: id)
  }

  /// Closing flushes Pi Durable's own state; it does not cancel the saved submission. Persist
  /// running until close completes, so a crash recovers it as interrupted and Resume cannot
  /// race cleanup. The attempt and runtime identity distinguish resumption of the same run ID.
  func interruptDeviceExecution(_ id: String, runID: String, attemptID: String, runtime: PiDurableRuntime) async {
    guard executionRecords[id]?.runID == runID, executionRecords[id]?.status == "running", localExecutionAttempts[id] == attemptID,
          localRuntimes[id] === runtime, !localInterrupting.contains(id), !localStopping.contains(id) else { return }
    localInterrupting.insert(id)
    defer { localInterrupting.remove(id) }
    localRunTokens.removeValue(forKey: id)
    localRunTasks.removeValue(forKey: id)?.cancel()
    executionRefreshTasks.removeValue(forKey: id)?.cancel()
    cancelDeviceApprovals(id)
    let snapshot = try? Self.executionObject(await runtime.snapshot())
    // Native history exports are intentionally deferred to reopening. Closing the exact runtime
    // promptly takes priority over paging a potentially large history at an OS expiration.
    try? await runtime.close()
    guard localExecutionAttempts[id] == attemptID, executionRecords[id]?.runID == runID else { return }
    if localRuntimes[id] === runtime { localRuntimes.removeValue(forKey: id) }
    executionRecords[id]?.goalLedger?.recover()
    if executionRecords[id]?.status == "running" { executionRecords[id]?.status = "interrupted" }
    try? persistExecutionConfiguration()
    if let record = executionRecords[id], let snapshot {
      let transcript = CompanionDeviceTranscript.project(snapshot: snapshot, conversationID: id,
        activeRunID: nil, runStatus: record.status)
      try? await adoptDeviceConversation(record, transcript: transcript)
      await reload()
    }
    finishDeviceExecutionAttempt(id, runID: runID, attemptID: attemptID, success: false)
    endIdleExecutionBackgroundTask()
  }

  func beginFallbackExecutionBackgroundTask() {
    guard !fixture, !isolatedTestHost, UIApplication.shared.applicationState == .background,
          backgroundTaskID == .invalid,
          executionRecords.values.contains(where: { record in
            guard record.runID != nil, ["running", "stopping"].contains(record.status), localRuntimes[record.id] != nil else { return false }
            return true
          }) else { return }
    let token = UUID()
    backgroundFallbackToken = token
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Save Quick Chat progress") { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.backgroundFallbackToken == token else { return }
        // Capture exact identities before the first await; a newly resumed runtime is unrelated.
        let runs = self.executionRecords.values.compactMap { record -> (String, String, String, PiDurableRuntime)? in
          guard let runID = record.runID, let runtime = self.localRuntimes[record.id],
                record.status == "running" else { return nil }
          let attemptID = self.localExecutionAttempts[record.id] ?? UUID().uuidString
          self.localExecutionAttempts[record.id] = attemptID
          return (record.id, runID, attemptID, runtime)
        }
        for (id, runID, attemptID, runtime) in runs {
          guard self.backgroundFallbackToken == token else { break }
          await self.interruptDeviceExecution(id, runID: runID, attemptID: attemptID, runtime: runtime)
        }
        if self.backgroundFallbackToken == token { self.endExecutionBackgroundTask() }
      }
    }
  }

  func endIdleExecutionBackgroundTask() {
    if !executionRecords.values.contains(where: { $0.runID != nil && ["running", "stopping"].contains($0.status) }) {
      endExecutionBackgroundTask()
    }
  }

  func endExecutionBackgroundTask() {
    backgroundFallbackToken = nil
    if backgroundTaskID != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTaskID)
      backgroundTaskID = .invalid
    }
  }
}
