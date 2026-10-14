import BackgroundTasks
import Foundation
import OSLog
import PiDurableRuntime
import UIKit

/// An OS allowance for work already started by the user; never a job scheduler or runtime owner.
/// On unsupported/denied devices, the existing short UIApplication background task remains in use.
@MainActor
final class DeviceBackgroundExecution {
  typealias Expiration = @MainActor () async -> Void
  private let logger = Logger(subsystem: "com.wovenmatter.companion", category: "DeviceBackgroundExecution")
  private var ledger = ContinuedExecutionLedger()
  private var grants: [String: BGTask] = [:]
  private var expirations: [String: Expiration] = [:]
  private(set) var lastSubmissionFailure: String?

  /// Call synchronously from a foreground, user-initiated submit/resume action. The callback must
  /// persist interruption and close that run only; it must not create a new submission or resume.
  func begin(conversationID: String, runID: String, title: String, onExpiration: @escaping Expiration) {
    guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active,
          let bundleID = Bundle.main.bundleIdentifier else { return }
    if let current = ledger.entry(conversationID: conversationID) {
      if current.identity.runID == runID { return }
      finish(conversationID: conversationID, runID: current.identity.runID, success: false)
    }
    let identity = ContinuedExecutionLedger.Identity(conversationID: conversationID, runID: runID,
      taskIdentifier: bundleID + ".pi-durable." + UUID().uuidString)
    guard ledger.request(identity) else { return }
    expirations[identity.taskIdentifier] = onExpiration

    // Concrete unique identifiers avoid duplicate registration and ambiguous wildcard handlers.
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identity.taskIdentifier, using: .main) { [weak self] task in
      MainActor.assumeIsolated {
        guard let self else { task.setTaskCompleted(success: false); return }
        self.receive(task, identity: identity)
      }
    }
    guard registered else {
      submissionFailed(identity, message: "Background task identifier is not permitted by this build.")
      return
    }
    let request = BGContinuedProcessingTaskRequest(identifier: identity.taskIdentifier,
      title: "Pi Durable", subtitle: String(title.prefix(100)))
    // The runtime is already executing. A queued request must never restart it later.
    request.strategy = .fail
    let submission = ContinuedTaskSubmission(request: request)
    Task { [weak self] in
      do {
        try await submission.submit()
        guard let self else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identity.taskIdentifier); return }
        // Work can finish during asynchronous submission. Cancel again after admission to avoid
        // an orphan request if the earlier cancellation arrived before this request was accepted.
        if self.ledger.entry(conversationID: conversationID)?.identity != identity {
          BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identity.taskIdentifier)
        }
      } catch {
        self?.submissionFailed(identity, message: error.localizedDescription)
      }
    }
  }

  func isContinuing(conversationID: String, runID: String) -> Bool {
    guard let entry = ledger.entry(conversationID: conversationID) else { return false }
    return entry.identity.runID == runID && entry.phase == .active
  }

  /// Call for real SDK progress events, not a wall-clock heartbeat. Agent workloads have an
  /// unknown final step count; the system receives completed steps plus the outstanding step.
  func advanceProgress(conversationID: String, runID: String, by completedUnits: Int64 = 1, subtitle: String = "Working") {
    guard let current = ledger.entry(conversationID: conversationID), current.identity.runID == runID,
          let entry = ledger.advance(current.identity, by: completedUnits) else { return }
    if #available(iOS 26.0, *), let task = grants[current.identity.taskIdentifier] as? BGContinuedProcessingTask {
      task.progress.totalUnitCount = entry.completedUnits + 1
      task.progress.completedUnitCount = entry.completedUnits
      task.updateTitle("Pi Durable", subtitle: String(subtitle.prefix(100)))
    }
  }

  func finish(conversationID: String, runID: String, success: Bool) {
    guard let current = ledger.entry(conversationID: conversationID), current.identity.runID == runID else { return }
    finish(current.identity, success: success)
  }

  private func finish(_ identity: ContinuedExecutionLedger.Identity, success: Bool) {
    guard let entry = ledger.finish(identity) else { return }
    expirations.removeValue(forKey: entry.identity.taskIdentifier)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: entry.identity.taskIdentifier)
    guard let task = grants.removeValue(forKey: entry.identity.taskIdentifier) else { return }
    // An expiration and a late runtime result must not report success for an interrupted run.
    let completed = success && entry.phase != .expiring
    if #available(iOS 26.0, *), completed, let continued = task as? BGContinuedProcessingTask {
      continued.progress.completedUnitCount = continued.progress.totalUnitCount
    }
    task.setTaskCompleted(success: completed)
  }

  @available(iOS 26.0, *)
  private func receive(_ task: BGTask, identity: ContinuedExecutionLedger.Identity) {
    guard let task = task as? BGContinuedProcessingTask, ledger.activate(identity) else {
      task.setTaskCompleted(success: false)
      return
    }
    grants[identity.taskIdentifier] = task
    let units = ledger.entry(conversationID: identity.conversationID)?.completedUnits ?? 0
    task.progress.totalUnitCount = units + 1
    task.progress.completedUnitCount = units
    task.expirationHandler = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.ledger.expire(identity) else { return }
        // Capture before suspension because completion may remove the callback while we yield.
        let interrupt = self.expirations[identity.taskIdentifier]
        await interrupt?()
        self.finish(identity, success: false)
      }
    }
    lastSubmissionFailure = nil
  }

  private func submissionFailed(_ identity: ContinuedExecutionLedger.Identity, message: String) {
    guard ledger.entry(conversationID: identity.conversationID)?.identity == identity else { return }
    lastSubmissionFailure = message
    logger.info("Continued execution unavailable; retaining durable short-task fallback: \(message, privacy: .public)")
    finish(identity, success: false)
  }
}

/// The request is frozen before crossing queues; BGTaskScheduler handles its own synchronization.
/// iOS 27 explicitly requires submitting off the main thread. Earlier SDKs retain the sync API.
@available(iOS 26.0, *)
private struct ContinuedTaskSubmission: @unchecked Sendable {
  let request: BGContinuedProcessingTaskRequest

  nonisolated func submit() async throws {
    try await Task.detached {
      #if compiler(>=6.4)
      if #available(iOS 27.0, *) {
        try await BGTaskScheduler.shared.submitTaskRequest(request)
        return
      }
      #endif
      try BGTaskScheduler.shared.submit(request)
    }.value
  }
}
