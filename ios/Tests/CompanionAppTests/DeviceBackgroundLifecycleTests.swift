import XCTest
import PiDurableRuntime
@testable import WovenMatterMobileApp

final class DeviceBackgroundLifecycleTests: XCTestCase {
  private let modelJSON = """
  {"id":"offline-test","name":"Offline test","api":"openai-responses","provider":"controlled","baseUrl":"https://invalid.test","reasoning":false,"input":["text"],"contextWindow":4096,"maxTokens":1024,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
  """

  @MainActor private func setup() async throws -> (CompanionModel, PiDurableRuntime, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("background-lifecycle-" + UUID().uuidString)
    let model = CompanionModel()
    model.executionDirectory = root
    await model.reload()
    model.selectedConversationID = "chat"
    model.executionRecords["chat"] = .init(id: "chat", title: "Offline lifecycle", connectionID: "test",
      modelJSON: modelJSON, runID: "saved-request", submissionID: 7, pendingInput: "Saved input", status: "running", updatedAt: CompanionModel.executionTimestamp())
    let runtime = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("runtime"),
      configuration: .init(conversationID: "chat", modelJSON: modelJSON),
      inference: { _, _ in XCTFail("Lifecycle tests must not invoke inference"); throw CancellationError() },
      tool: { _ in XCTFail("Lifecycle tests must not invoke tools"); throw CancellationError() })
    try await runtime.open()
    model.localRuntimes["chat"] = runtime
    model.localExecutionAttempts["chat"] = "current-attempt"
    model.localRunTokens["chat"] = "observer"
    try model.persistExecutionConfiguration()
    return (model, runtime, root)
  }

  @MainActor func testInterruptionClosesExactRuntimeAndPreservesSavedSubmission() async throws {
    let (model, runtime, root) = try await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertFalse(model.canResumeLocalRun)
    await model.interruptDeviceExecution("chat", runID: "saved-request", attemptID: "current-attempt", runtime: runtime)
    XCTAssertNil(model.localRuntimes["chat"])
    XCTAssertNil(model.localRunTokens["chat"])
    XCTAssertNil(model.localExecutionAttempts["chat"])
    XCTAssertFalse(model.localInterrupting.contains("chat"))
    XCTAssertEqual(model.executionRecords["chat"]?.status, "interrupted")
    XCTAssertEqual(model.executionRecords["chat"]?.runID, "saved-request")
    XCTAssertEqual(model.executionRecords["chat"]?.submissionID, 7)
    XCTAssertEqual(model.executionRecords["chat"]?.pendingInput, "Saved input")
    XCTAssertTrue(model.canResumeLocalRun)
    do { _ = try await runtime.snapshot(); XCTFail("Interrupted runtime must be closed") }
    catch PiDurableRuntimeError.closed { }
    let preferences = try JSONDecoder().decode(DeviceExecutionPreferences.self, from: Data(contentsOf: root.appendingPathComponent("preferences.json")))
    XCTAssertEqual(preferences.conversations["chat"]?.status, "interrupted")
    XCTAssertEqual(preferences.conversations["chat"]?.runID, "saved-request")
  }

  @MainActor func testStaleAttemptCannotInterruptResumedRunWithSameRequestID() async throws {
    let (model, runtime, root) = try await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    await model.interruptDeviceExecution("chat", runID: "saved-request", attemptID: "previous-attempt", runtime: runtime)
    XCTAssertTrue(model.localRuntimes["chat"] === runtime)
    XCTAssertEqual(model.localExecutionAttempts["chat"], "current-attempt")
    XCTAssertEqual(model.executionRecords["chat"]?.status, "running")
    _ = try await runtime.snapshot()
    try await runtime.close()
  }

  @MainActor func testPauseCleanupCannotRaceAnExplicitStop() async throws {
    let (model, runtime, root) = try await setup()
    defer { try? FileManager.default.removeItem(at: root) }
    model.localStopping.insert("chat")
    model.executionRecords["chat"]?.status = "stopping"
    await model.interruptDeviceExecution("chat", runID: "saved-request", attemptID: "current-attempt", runtime: runtime)
    XCTAssertEqual(model.executionRecords["chat"]?.status, "stopping")
    XCTAssertTrue(model.localRuntimes["chat"] === runtime)
    _ = try await runtime.snapshot()
    try await runtime.close()
  }
}
