import Foundation
import PiDurableRuntime
import UIKit
import WovenMatterCompanion

extension CompanionModel {
  @discardableResult
  func beginDeviceExecutionAttempt(_ id: String, runID: String, runtime: PiDurableRuntime, userInitiated: Bool) -> String {
    let attemptID = UUID().uuidString
    localExecutionAttempts[id] = attemptID
    if userInitiated && !fixture && !isolatedTestHost {
      deviceBackgroundExecution.begin(conversationID: id, runID: runID, title: executionRecords[id]?.title ?? "Agent run") { [weak self, weak runtime] in
        guard let self, let runtime else { return }
        await self.interruptDeviceExecution(id, runID: runID, attemptID: attemptID, runtime: runtime)
      }
    }
    beginFallbackExecutionBackgroundTask()
    return attemptID
  }

  func finishDeviceExecutionAttempt(_ id: String, runID: String, attemptID: String?, success: Bool) {
    if let attemptID, localExecutionAttempts[id] != attemptID { return }
    deviceBackgroundExecution.finish(conversationID: id, runID: runID, success: success)
    localExecutionAttempts.removeValue(forKey: id)
  }

  func recordDeviceExecutionProgress(_ id: String, events: String) {
    guard let runID = executionRecords[id]?.runID, executionRecords[id]?.status == "running",
          !localInterrupting.contains(id), let object = try? Self.executionObject(events),
          let events = object["events"] as? [[String: Any]] else { return }
    // A completed message/tool is real work. Polls, snapshots, timers and watchdog heartbeats
    // are not progress and must not keep an otherwise stalled OS task artificially alive.
    let completed = events.filter { ["message_end", "tool_execution_end"].contains($0["type"] as? String ?? "") }.count
    guard completed > 0 else { return }
    deviceBackgroundExecution.advanceProgress(conversationID: id, runID: runID, by: Int64(completed), subtitle: "Agent running")
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
    await refreshDeviceToolSubmissions()
  }

  func beginFallbackExecutionBackgroundTask() {
    guard !fixture, !isolatedTestHost, UIApplication.shared.applicationState == .background,
          backgroundTaskID == .invalid,
          (DeviceCLIExecutorJobs.hasUncontinuedJobs { self.hasDeviceContinuation($0) } || executionRecords.values.contains(where: { record in
            guard let runID = record.runID, ["running", "stopping"].contains(record.status), localRuntimes[record.id] != nil else { return false }
            return !deviceBackgroundExecution.isContinuing(conversationID: record.id, runID: runID)
          })) else { return }
    let token = UUID()
    backgroundFallbackToken = token
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Save Pi Durable progress") { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.backgroundFallbackToken == token else { return }
        DeviceCLIExecutorJobs.cancelWithoutContinuation { self.hasDeviceContinuation($0) }
        // Capture exact identities before the first await; a newly resumed runtime is unrelated.
        let runs = self.executionRecords.values.compactMap { record -> (String, String, String, PiDurableRuntime)? in
          guard let runID = record.runID, let runtime = self.localRuntimes[record.id],
                record.status == "running",
                !self.deviceBackgroundExecution.isContinuing(conversationID: record.id, runID: runID) else { return nil }
          let attemptID = self.localExecutionAttempts[record.id] ?? UUID().uuidString
          self.localExecutionAttempts[record.id] = attemptID
          return (record.id, runID, attemptID, runtime)
        }
        for (id, runID, attemptID, runtime) in runs {
          guard self.backgroundFallbackToken == token else { break }
          if !self.deviceBackgroundExecution.isContinuing(conversationID: id, runID: runID) {
            await self.interruptDeviceExecution(id, runID: runID, attemptID: attemptID, runtime: runtime)
          }
        }
        if self.backgroundFallbackToken == token { self.endExecutionBackgroundTask() }
      }
    }
  }

  private func hasDeviceContinuation(_ id: String) -> Bool {
    guard let runID = executionRecords[id]?.runID else { return false }
    return deviceBackgroundExecution.isContinuing(conversationID: id, runID: runID)
  }

  func endIdleExecutionBackgroundTask() {
    if !DeviceCLIExecutorJobs.hasUncontinuedJobs({ self.hasDeviceContinuation($0) }) && !executionRecords.values.contains(where: { $0.runID != nil && ["running", "stopping"].contains($0.status) }) {
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
