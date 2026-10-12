import SwiftUI
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  /// iOS schedules are evaluated while the app has execution time. Missed work
  /// retains its device owner and is claimed durably when this device returns.
  func startDeviceScheduler() {
    guard !fixture, !isolatedTestHost, deviceScheduleTask == nil else { return }
    deviceScheduleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.processDeviceSchedule()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  func stopDeviceScheduler() {
    deviceScheduleTask?.cancel(); deviceScheduleTask = nil
  }

  func processDeviceSchedule() async {
    guard !fixture, !isolatedTestHost, initialized, !processingDeviceSchedule, let store else { return }
    processingDeviceSchedule = true
    defer { processingDeviceSchedule = false }
    let previousRuns = await store.calendar.runs()
    do {
      try Task.checkCancellation()
      await processDeviceToolSubmissions()
      try Task.checkCancellation()
      // Reconcile by immutable request ID, never by the selected chat or its
      // latest visible status. A later conversation run cannot finish this task.
      for run in await store.calendar.runs() where run.ownerDeviceID == deviceWorkspaceID && run.status == "running" {
        try Task.checkCancellation()
        if let submission = await store.toolSubmission(requestID: run.id) {
          let status: String?
          switch submission.state {
          case "completed": status = "completed"
          case "failed": status = "failed"
          case "cancelled", "stopped": status = "cancelled"
          default: status = nil
          }
          if let status { try await store.calendar.updateRun(run.id, status: status, error: submission.error) }
        } else {
          // A claim may have committed just before process termination. Enqueue
          // only its original request ID; the inbox and SDK both deduplicate it.
          do {
            if let recovered = try await store.calendar.recoverRun(run.id) {
              try Task.checkCancellation()
              _ = try await submitDevicePrompt(sessionID: recovered.sessionID, requestID: recovered.id, text: recovered.task.prompt)
            }
          } catch is CancellationError { throw CancellationError() }
          catch { /* Keep this claim for inspection without starving other tasks. */ }
        }
      }
      for pending in try await store.calendar.dueRuns(deviceID: deviceWorkspaceID) {
        try Task.checkCancellation()
        // Leave unconfigured work pending. Adding a provider later must not lose
        // a missed one-time task, nor silently move it to the central Mac.
        guard inferenceConnections.contains(where: { $0.id == inferenceConnectionID }) else { continue }
        guard ["pi", "pi-durable", "default_agent"].contains(pending.task.runtime) else {
          try await store.calendar.updateRun(pending.id, status: "failed", error: "This scheduled agent is not available on this device.")
          continue
        }
        do {
          try await createDeviceToolSession(id: pending.sessionID, title: pending.title,
            folderID: pending.task.folderID, model: pending.task.model, thinking: pending.task.thinking, enabledTools: pending.task.enabledTools)
          try Task.checkCancellation()
          // Final revision/ownership check happens after preparing the session,
          // immediately before handing the immutable claim to the durable inbox.
          let run = try await store.calendar.beginRun(pending.id)
          try Task.checkCancellation()
          _ = try await submitDevicePrompt(sessionID: run.sessionID, requestID: run.id, text: run.task.prompt)
        } catch is CancellationError { throw CancellationError() }
        catch {
          // Retain pending/running identity for receipt recovery. The error is
          // shown with the task rather than as a global connectivity banner.
          let current = await store.calendar.runs().first { $0.id == pending.id }
          if let current, ["pending", "running"].contains(current.status) {
            try await store.calendar.updateRun(current.id, status: current.status, error: error.localizedDescription)
          }
        }
      }
      for timer in try await store.claimDueToolTimers() {
        try Task.checkCancellation()
        guard let fireID = timer.pendingFireID, let record = executionRecords[timer.sessionID], record.isTrashed != true else { continue }
        do {
          // Pause/remove/update may invalidate a captured claim while earlier timers await.
          // Validate, enqueue, and advance the timer in one actor transaction before execution.
          if try await store.enqueueClaimedToolTimer(id: timer.id, fireID: fireID) != nil {
            try Task.checkCancellation()
            await processDeviceToolSubmissions()
          }
        } catch is CancellationError { throw CancellationError() }
        catch { /* Retain this fire ID, while allowing unrelated timers to proceed. */ }
      }
    } catch is CancellationError { }
    catch { /* Persistent claims remain available for the next execution window. */ }
    if await store.calendar.runs() != previousRuns { calendarRevision &+= 1 }
  }
}
