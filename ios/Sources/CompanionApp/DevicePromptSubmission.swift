import Foundation
import CompanionClient
import CompanionInference
import PiDurableRuntime
import WovenMatterCompanion

@MainActor private enum DeviceToolSubmissionTasks {
  static var starting = Set<String>()
}
extension CompanionModel {
  /// Delivers a fired timer to its Quick Chat. A durable inbox acknowledges
  /// acceptance separately from run completion; the SDK's stable request ID makes
  /// a crash around submit recoverable without a duplicate turn. Delivery never
  /// changes the user's open chat or draft.
  func submitDevicePrompt(sessionID: String, requestID: String, text: String) async throws -> MobileToolSubmission {
    try Task.checkCancellation()
    guard let store, executionRecords[sessionID]?.quickChatVersion == 1, executionRecords[sessionID]?.isTrashed != true else { throw WorkspaceToolError.notFound("This chat is not a Quick Chat on this device.") }
    let job = try await store.enqueueToolSubmission(id: requestID, sessionID: sessionID, text: text)
    if job.state == "queued" { try await startDeviceToolSubmission(job) }
    return await store.toolSubmission(requestID: requestID) ?? job
  }
  private func startDeviceToolSubmission(_ job: MobileToolSubmission) async throws {
    try Task.checkCancellation()
    guard let store, let record = executionRecords[job.sessionID], record.quickChatVersion == 1, record.isTrashed != true else { throw WorkspaceToolError.notFound("The Quick Chat is no longer available.") }
    let id = job.sessionID
    guard !DeviceToolSubmissionTasks.starting.contains(id), !localStopping.contains(id), !localInterrupting.contains(id), !configuringDeviceSessions.contains(id) else { return }
    if let runID = record.runID, runID != job.id { return }
    if localRunTasks[id] != nil { return }
    DeviceToolSubmissionTasks.starting.insert(id); configuringDeviceSessions.insert(id)
    defer { DeviceToolSubmissionTasks.starting.remove(id); configuringDeviceSessions.remove(id) }
    var activeRuntime: PiDurableRuntime?
    var attemptID: String?
    try await store.updateToolSubmission(id: job.id, state: "submitting")
    executionRecords[id]?.runID = job.id; executionRecords[id]?.pendingInput = Self.timerDeliveryPrompt(job.text); executionRecords[id]?.inputAssetID = nil
    executionRecords[id]?.status = "running"; executionRecords[id]?.updatedAt = Self.executionTimestamp()
    do {
      try persistExecutionConfiguration()
      try Task.checkCancellation()
      let runtime = try await deviceRuntime(id)
      activeRuntime = runtime
      try Task.checkCancellation()
      guard executionRecords[id]?.runID == job.id, executionRecords[id]?.status == "running", !localInterrupting.contains(id), !localStopping.contains(id) else { throw CancellationError() }
      executionRecords[id]?.goalUsageBaseline = try await runtime.tokenUsage()
      try persistExecutionConfiguration()
      attemptID = beginDeviceExecutionAttempt(id, runID: job.id, runtime: runtime, userInitiated: false)
      let receipt = try Self.executionObject(await runtime.submit(text: Self.timerDeliveryPrompt(job.text), requestID: job.id))
      guard executionRecords[id]?.runID == job.id, executionRecords[id]?.status == "running" else { throw CancellationError() }
      guard let submissionID = (receipt["submissionId"] ?? receipt["submissionID"] ?? receipt["id"]) as? Int else { throw DeviceExecutionError.unavailable("Pi Durable did not return a saved submission receipt.") }
      executionRecords[id]?.submissionID = submissionID; executionRecords[id]?.pendingInput = nil
      try persistExecutionConfiguration()
      try await store.updateToolSubmission(id: job.id, state: "accepted")
      observeDeviceRun(id, submissionID: submissionID, runtime: runtime)
      await refreshDeviceTranscript(id)
    } catch {
      if let activeRuntime, let attemptID {
        await interruptDeviceExecution(id, runID: job.id, attemptID: attemptID, runtime: activeRuntime)
      } else if executionRecords[id]?.runID == job.id, executionRecords[id]?.status == "running" {
        executionRecords[id]?.status = "interrupted"; try? persistExecutionConfiguration()
      }
      try? await store.updateToolSubmission(id: job.id, state: "interrupted", error: error.localizedDescription)
      throw error
    }
  }
  /// The agent sees which timer fired; the text is what it set for the user.
  static func timerDeliveryPrompt(_ text: String) -> String {
    "<wovenmatter-timer>\nA timer you set in this chat is due. Its text:\n" + text + "\n</wovenmatter-timer>"
  }
  func processDeviceToolSubmissions() async {
    guard let store, !Task.isCancelled else { return }
    await refreshDeviceToolSubmissions()
    for job in await store.toolSubmissions() where job.state == "queued" {
      guard !Task.isCancelled else { return }
      guard executionRecords[job.sessionID]?.quickChatVersion == 1 else { continue }
      do { try await startDeviceToolSubmission(job) }
      catch { /* durable inbox retains the pending request for explicit resume */ }
    }
  }
  func completeDeviceToolSubmission(requestID: String, status: String, error: String? = nil) async throws {
    guard let store else { return }
    let recorded = await store.toolSubmission(requestID: requestID)
    guard let sessionID = recorded?.sessionID ?? executionRecords.values.first(where: { $0.runID == requestID })?.id else { return }
    try await store.completeLocalToolRun(sessionID: sessionID, requestID: requestID, status: status, error: error)
  }
  func refreshDeviceToolSubmissions() async {
    guard let store else { return }
    for job in await store.toolSubmissions() where ["accepted", "submitting"].contains(job.state) {
      guard let record = executionRecords[job.sessionID], localRunTasks[job.sessionID] == nil else { continue }
      // A latest conversation status cannot prove the outcome of an older
      // submission. Only the observer with this exact run ID records completion.
      if record.runID == job.id, record.status == "interrupted" {
        try? await store.updateToolSubmission(id: job.id, state: "interrupted")
      } else if record.runID == nil, job.state == "submitting" {
        executionRecords[job.sessionID]?.runID = job.id
        executionRecords[job.sessionID]?.pendingInput = Self.timerDeliveryPrompt(job.text); executionRecords[job.sessionID]?.inputAssetID = nil
        executionRecords[job.sessionID]?.status = "interrupted"
        try? persistExecutionConfiguration()
        try? await store.updateToolSubmission(id: job.id, state: "interrupted")
      }
    }
  }
}
