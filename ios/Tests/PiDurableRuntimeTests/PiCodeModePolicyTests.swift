import XCTest
@testable import PiDurableRuntime

@MainActor
final class PiCodeModePolicyTests: XCTestCase {
  private func request(_ source: String, tools: [[String: String]] = []) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["source": source, "state": [:], "tools": tools]), as: UTF8.self)
  }

  func testWaitingForToolDoesNotConsumeResponsivenessBudget() async throws {
    let executor = PiCodeModeExecutor()
    let output = try await executor.run(requestJSON: request("text(await tools.wait_for_approval({}));", tools: [["name": "wait_for_approval"]]),
      policy: .init(unresponsiveCodeSeconds: 2)) { _, _ in
        try await Task.sleep(for: .seconds(3))
        return "{\"approved\":true}"
      }
    XCTAssertTrue(output.contains("approved"))
  }

  func testWorkerQueuesToolsToConfiguredConcurrencyAndCheckpointsAfterCompletion() async throws {
    let executor = PiCodeModeExecutor()
    var active = 0, peak = 0, completed = 0
    var checkpoint: String?
    let source = "await Promise.all(Array.from({length:12},(_,i)=>tools.count({i}))); store('done',true); await checkpoint(); text('finished');"
    let output = try await executor.run(requestJSON: request(source, tools: [["name": "count"]]),
      policy: .init(concurrentTools: 2), checkpoint: { checkpoint = $0 }) { _, _ in
        active += 1; peak = max(peak, active)
        try await Task.sleep(for: .milliseconds(20))
        active -= 1; completed += 1
        return "{}"
      }
    XCTAssertEqual(completed, 12)
    XCTAssertLessThanOrEqual(peak, 2)
    XCTAssertTrue(checkpoint?.contains("true") == true)
    XCTAssertTrue(output.contains("finished"))
  }

  func testUnresponsiveWorkerAndExplicitStopRemainTerminable() async throws {
    let executor = PiCodeModeExecutor()
    do {
      _ = try await executor.run(requestJSON: request("while(true){}"), policy: .init(unresponsiveCodeSeconds: 1)) { _, _ in "{}" }
      XCTFail("Unresponsive program completed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("stopped responding")) }
    let second = PiCodeModeExecutor()
    let task = Task { try await second.run(requestJSON: request("while(true){}")) { _, _ in "{}" } }
    try await Task.sleep(for: .milliseconds(300)); task.cancel()
    do { _ = try await task.value; XCTFail("Stopped program completed") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
  }

  func testInvalidResourcePolicyRejected() throws {
    XCTAssertThrowsError(try PiExecutionPolicy(unresponsiveCodeSeconds: .infinity).validated())
    XCTAssertThrowsError(try PiExecutionPolicy(concurrentTools: 0).validated())
    XCTAssertThrowsError(try PiExecutionPolicy(subagentDepth: 0).validated())
  }
}
