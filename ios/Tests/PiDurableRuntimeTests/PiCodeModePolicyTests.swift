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

  func testWorkerStartsAllParallelToolsAndCheckpointsAfterCompletion() async throws {
    let executor = PiCodeModeExecutor()
    var started = 0, active = 0, peak = 0, completed = 0
    var checkpoint: String?
    let source = "await Promise.all(Array.from({length:32},(_,i)=>tools.count({i}))); store('done',true); await checkpoint(); text('finished');"
    let output = try await executor.run(requestJSON: request(source, tools: [["name": "count"]]),
      checkpoint: { checkpoint = $0 }) { _, _ in
        started += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        // No call may finish before the entire batch is admitted. The old queue
        // would deadlock here even if all calls eventually completed in batches.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while started < 32 {
          guard ContinuousClock.now < deadline else {
            XCTFail("Parallel tools were held behind a concurrency ceiling.")
            throw CancellationError()
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        completed += 1
        return "{}"
      }
    XCTAssertEqual(completed, 32)
    XCTAssertEqual(peak, 32)
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

  func testLegacyDepthAlwaysNormalizesToRootAndOneChildLevel() throws {
    for value in 1...4 { XCTAssertEqual(try PiExecutionPolicy(subagentDepth: value).validated().subagentDepth, 2) }
  }

  func testRestoredPoliciesRaiseLegacyWatchdogWithoutReducingLongerBudgets() throws {
    for (saved, expected) in [(30.0, 120.0), (120.0, 120.0), (240.0, 240.0)] {
      let original = PiExecutionPolicy(unresponsiveCodeSeconds: saved, concurrentSubagents: 3)
      let restored = try JSONDecoder().decode(PiExecutionPolicy.self, from: JSONEncoder().encode(original)).validated()
      XCTAssertEqual(restored.unresponsiveCodeSeconds, expected)
      XCTAssertEqual(restored.concurrentSubagents, 3)
    }
  }

  func testLegacyToolConcurrencyIsIgnoredAndNotPersisted() throws {
    for oldLimit in [0, 1, 16, 128] {
      let data = try JSONSerialization.data(withJSONObject: [
        "unresponsiveCodeSeconds": 30, "concurrentTools": oldLimit,
        "concurrentSubagents": 3, "subagentDepth": 2,
      ])
      let restored = try JSONDecoder().decode(PiExecutionPolicy.self, from: data).validated()
      XCTAssertEqual(restored.unresponsiveCodeSeconds, 120)
      XCTAssertEqual(restored.concurrentSubagents, 3)
      let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
      XCTAssertNil(encoded["concurrentTools"])
    }
  }

  func testInvalidResourcePolicyRejected() throws {
    XCTAssertThrowsError(try PiExecutionPolicy(unresponsiveCodeSeconds: .infinity).validated())
    XCTAssertThrowsError(try PiExecutionPolicy(subagentDepth: 0).validated())
  }
}
