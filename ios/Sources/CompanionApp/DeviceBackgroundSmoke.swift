#if DEBUG
import Foundation
import CompanionClient
import CompanionInference
import PiDurableRuntime
import WovenMatterCompanion

/// Runs inside the isolated debug smoke host; all model responses are generated in memory.
/// No app-owned user library, provider network, or Keychain is opened by these fixtures.
@MainActor enum DeviceBackgroundSmoke {
  static func run(root: URL, descriptor: InferenceModel) async throws -> [String: Any] {
    let store = try MobileStore(file: root.appendingPathComponent("background-library/library.json"))
    let offline = BackgroundSmokeLibrary()
    let model = CompanionModel(store: store, transport: offline)
    model.executionDirectory = root.appendingPathComponent("background-execution")
    model.initialized = true
    await model.reload()
    let host = BackgroundSmokeInference()
    let sessionID = UUID().uuidString.lowercased(), requestID = UUID().uuidString.lowercased()
    let config = PiDurableConfiguration(conversationID: sessionID, modelJSON: try descriptor.descriptorJSON())
    let storage = root.appendingPathComponent("background-runtime")
    func openRuntime() async throws -> PiDurableRuntime {
      let runtime = try PiDurableRuntime(storageDirectory: storage, configuration: config,
        inference: { try await host.hold($0, emit: $1) }, tool: { _ in throw DeviceExecutionError.unavailable("No tools belong to this fixture.") })
      try await runtime.open()
      return runtime
    }
    let runtime = try await openRuntime()
    let accepted = try object(await runtime.submit(text: "Controlled in-flight work", requestID: requestID))
    guard let submissionID = accepted["id"] as? Int else { throw CocoaError(.coderReadCorrupt) }
    model.executionRecords[sessionID] = .init(id: sessionID, title: "Lifecycle fixture", connectionID: "fixture",
      modelJSON: config.modelJSON, runID: requestID, submissionID: submissionID, status: "running", updatedAt: CompanionModel.executionTimestamp())
    model.selectedConversationID = sessionID
    model.localRuntimes[sessionID] = runtime
    model.localExecutionAttempts[sessionID] = "first-attempt"
    model.observeDeviceRun(sessionID, submissionID: submissionID, runtime: runtime)
    for _ in 0..<100 { if await host.heldCalls > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    await model.interruptDeviceExecution(sessionID, runID: requestID, attemptID: "first-attempt", runtime: runtime)
    guard model.localRuntimes[sessionID] == nil, model.localRunTasks[sessionID] == nil,
          model.executionRecords[sessionID]?.status == "interrupted", model.canResumeLocalRun,
          model.executionRecords[sessionID]?.runID == requestID, model.executionRecords[sessionID]?.submissionID == submissionID else {
      throw DeviceExecutionError.unavailable("Interruption failed to preserve the exact resumable submission.")
    }
    do { _ = try await runtime.snapshot(); throw DeviceExecutionError.unavailable("Interrupted runtime was not closed.") }
    catch PiDurableRuntimeError.closed { }
    let reopened = try await openRuntime()
    let callsBefore = await host.heldCalls
    model.localRuntimes[sessionID] = reopened
    model.localExecutionAttempts[sessionID] = "second-attempt"
    model.executionRecords[sessionID]?.status = "running"
    await model.interruptDeviceExecution(sessionID, runID: requestID, attemptID: "first-attempt", runtime: runtime)
    guard model.localRuntimes[sessionID] === reopened, model.executionRecords[sessionID]?.status == "running" else {
      throw DeviceExecutionError.unavailable("A stale expiration interrupted the replacement runtime.")
    }
    _ = try await reopened.snapshot()
    guard await host.heldCalls == callsBefore else { throw DeviceExecutionError.unavailable("Opening saved state unexpectedly resumed inference.") }
    await model.interruptDeviceExecution(sessionID, runID: requestID, attemptID: "second-attempt", runtime: reopened)

    // A task missed while offline is claimed by this device and completes through the same
    // durable submission inbox/observer path used by the scheduler, never selected-chat state.
    let event = try await store.calendar.save(expectedRevision: nil,
      draft: .init(title: "Offline scheduled fixture", startsAt: Date().addingTimeInterval(-120), task: .init(prompt: "Complete the controlled scheduled fixture")),
      ownerDeviceID: model.deviceWorkspaceID)
    guard let scheduled = try await store.calendar.dueRuns(deviceID: model.deviceWorkspaceID).first(where: { $0.eventID == event.id }) else {
      throw DeviceExecutionError.unavailable("The assigned device did not claim its missed scheduled task.")
    }
    let scheduledConfig = PiDurableConfiguration(conversationID: scheduled.sessionID, modelJSON: config.modelJSON)
    let scheduledRuntime = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("scheduled-runtime"), configuration: scheduledConfig,
      inference: { try await host.complete($0, emit: $1) }, tool: { _ in throw DeviceExecutionError.unavailable("No tools belong to this fixture.") })
    try await scheduledRuntime.open()
    model.localRuntimes[scheduled.sessionID] = scheduledRuntime
    model.executionRecords[scheduled.sessionID] = .init(id: scheduled.sessionID, title: scheduled.title,
      connectionID: "fixture", modelJSON: config.modelJSON, status: "ready", updatedAt: CompanionModel.executionTimestamp())
    let connection = InferenceConnection(id: "fixture", name: "Controlled fixture", provider: "openai", route: .direct, modelID: descriptor.id)
    model.inferenceConnections = [connection]; model.inferenceConnectionID = connection.id
    try model.persistExecutionConfiguration()
    await model.processDeviceSchedule()
    for _ in 0..<300 {
      if await store.toolSubmission(requestID: scheduled.id)?.state == "completed", model.localRunTasks[scheduled.sessionID] == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.processDeviceSchedule()
    guard let completed = await store.calendar.runs().first(where: { $0.id == scheduled.id }), completed.status == "completed",
          completed.ownerDeviceID == model.deviceWorkspaceID,
          await store.toolSubmission(requestID: scheduled.id)?.state == "completed", await host.completedCalls == 1 else {
      throw DeviceExecutionError.unavailable("The scheduled task did not retain one device-owned terminal receipt.")
    }
    await model.processDeviceSchedule()
    guard await host.completedCalls == 1, await offline.calls == 0 else {
      throw DeviceExecutionError.unavailable("The scheduler repeated work or attempted a central connection.")
    }
    try await scheduledRuntime.close()
    return ["lifecycleInterruptionOnIOS": true, "lifecycleSubmissionPreserved": true,
      "lifecycleStaleExpirationIgnored": true, "lifecycleOpenDoesNotResume": true,
      "scheduledTaskOnAssignedDevice": true, "scheduledTaskExactReceipt": true, "scheduledTaskDuplicateRuns": 0]
  }

  private static func object(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
    return object
  }
}

private actor BackgroundSmokeInference {
  var heldCalls = 0
  var completedCalls = 0
  func hold(_ request: String, emit: @escaping @Sendable (String) -> Void) async throws {
    heldCalls += 1
    try await Task.sleep(for: .seconds(3_600))
    throw CancellationError()
  }
  func complete(_ request: String, emit: @escaping @Sendable (String) -> Void) throws {
    completedCalls += 1
    let message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "Completed offline scheduled fixture"]],
      "api": "openai-responses", "provider": "openai", "model": "offline-smoke", "stopReason": "stop", "timestamp": Date().timeIntervalSince1970 * 1_000,
      "usage": ["input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 2, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]]
    let event: [String: Any] = ["type": "done", "reason": "stop", "message": message]
    emit(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
  }
}

private actor BackgroundSmokeLibrary: CompanionTransport {
  var calls = 0
  private func unavailable() -> MobileConnectionError { calls += 1; return .offline }
  func workspaceIdentity() async throws -> String { throw unavailable() }
  func snapshot() async throws -> CompanionSnapshot { throw unavailable() }
  func changes(after: Int64) async throws -> CompanionChangePage { throw unavailable() }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult { throw unavailable() }
  func note(_ id: String) async throws -> CompanionNote { throw unavailable() }
  func providers() async throws -> [CompanionProvider] { throw unavailable() }
  func pending() async throws -> [CompanionPendingInteraction] { throw unavailable() }
  func transcript(_ id: String) async throws -> CompanionTranscript { throw unavailable() }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { throw unavailable() }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { throw unavailable() }
}
#endif
