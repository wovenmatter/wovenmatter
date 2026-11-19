import XCTest
@testable import PiDurableRuntime

@MainActor
final class PiCodeModePolicyTests: XCTestCase {
  private func request(_ source: String, tools: [[String: String]] = []) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["source": source, "state": [:], "tools": tools]), as: UTF8.self)
  }

  func testWaitingForToolDoesNotConsumeResponsivenessBudget() async throws {
    // The budget clock moves only when this test moves it, one second at a time
    // and only after the worker's next heartbeat arrived. The tool's wait spans
    // five budget-clock seconds against a two-second budget, so the run completes
    // only if the worker keeps heartbeating while it awaits the tool; a slow
    // machine can delay heartbeats but can no longer age one past the budget.
    let base = ContinuousClock.now
    var elapsed = Duration.zero
    let executor = PiCodeModeExecutor(now: { base.advanced(by: elapsed) })
    let output = try await executor.run(requestJSON: request("text(await tools.wait_for_approval({}));", tools: [["name": "wait_for_approval"]]),
      policy: .init(unresponsiveCodeSeconds: 2)) { _, _ in
        for _ in 0..<5 {
          elapsed += .seconds(1)
          let seen = executor.heartbeats, deadline = ContinuousClock.now.advanced(by: .seconds(30))
          while executor.heartbeats == seen {
            guard ContinuousClock.now < deadline else {
              XCTFail("The worker stopped heartbeating while it awaited a tool (after \(seen) heartbeats, \(elapsed) on the budget clock).")
              throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
          }
        }
        return "{\"approved\":true}"
      }
    XCTAssertTrue(output.contains("approved"))
    XCTAssertEqual(elapsed, .seconds(5))
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

  func testASavedPolicyIsReadAsWrittenAndInvalidOnesAreRefused() throws {
    let saved = try JSONEncoder().encode(PiExecutionPolicy(unresponsiveCodeSeconds: 240, concurrentSubagents: 3, subagentDepth: 4))
    let restored = try JSONDecoder().decode(PiExecutionPolicy.self, from: saved).validated()
    XCTAssertEqual(restored, PiExecutionPolicy(unresponsiveCodeSeconds: 240, concurrentSubagents: 3, subagentDepth: 2))
    XCTAssertThrowsError(try PiExecutionPolicy(unresponsiveCodeSeconds: .infinity).validated())
    XCTAssertThrowsError(try PiExecutionPolicy(subagentDepth: 0).validated())
  }

}
