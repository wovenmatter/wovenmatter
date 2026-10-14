import XCTest
@testable import PiDurableRuntime

final class ContinuedExecutionLedgerTests: XCTestCase {
  private func identity(_ run: String = "run-1", conversation: String = "chat") -> ContinuedExecutionLedger.Identity {
    .init(conversationID: conversation, runID: run, taskIdentifier: "app.pi-durable." + run)
  }

  func testLateGrantCannotResumeFinishedRun() {
    var ledger = ContinuedExecutionLedger()
    let run = identity()
    XCTAssertTrue(ledger.request(run))
    XCTAssertNotNil(ledger.finish(run))
    XCTAssertFalse(ledger.activate(run))
    XCTAssertFalse(ledger.expire(run))
    XCTAssertNil(ledger.entry(conversationID: "chat"))
  }

  func testStaleExpirationAndCompletionCannotTouchNewGeneration() {
    var ledger = ContinuedExecutionLedger()
    let old = identity(), new = identity("run-2")
    XCTAssertTrue(ledger.request(old))
    XCTAssertTrue(ledger.activate(old))
    XCTAssertNotNil(ledger.finish(old))
    XCTAssertTrue(ledger.request(new))
    XCTAssertTrue(ledger.activate(new))
    XCTAssertFalse(ledger.expire(old))
    XCTAssertNil(ledger.finish(old))
    XCTAssertNil(ledger.advance(old))
    XCTAssertEqual(ledger.entry(conversationID: "chat")?.identity, new)
    XCTAssertEqual(ledger.entry(conversationID: "chat")?.phase, .active)
  }

  func testExpirationIsDeliveredOnceAndRemainsUnsuccessfulAfterCompletionRace() {
    var ledger = ContinuedExecutionLedger()
    let run = identity()
    XCTAssertTrue(ledger.request(run))
    XCTAssertFalse(ledger.request(run))
    XCTAssertTrue(ledger.activate(run))
    XCTAssertFalse(ledger.activate(run))
    XCTAssertTrue(ledger.expire(run))
    XCTAssertFalse(ledger.expire(run))
    XCTAssertNil(ledger.advance(run))
    XCTAssertEqual(ledger.finish(run)?.phase, .expiring)
    XCTAssertNil(ledger.finish(run))
  }

  func testExpirationCompletionCannotFinishAResumedAttemptOfTheSameSubmission() {
    var ledger = ContinuedExecutionLedger()
    let old = identity()
    let resumed = ContinuedExecutionLedger.Identity(conversationID: old.conversationID,
      runID: old.runID, taskIdentifier: "app.pi-durable.resumed-attempt")
    XCTAssertTrue(ledger.request(old))
    XCTAssertTrue(ledger.activate(old))
    XCTAssertTrue(ledger.expire(old))
    XCTAssertNotNil(ledger.finish(old))
    XCTAssertTrue(ledger.request(resumed))
    XCTAssertTrue(ledger.activate(resumed))
    XCTAssertNil(ledger.finish(old))
    XCTAssertFalse(ledger.expire(old))
    XCTAssertEqual(ledger.entry(conversationID: "chat")?.identity, resumed)
  }

  func testUnavailableSubmissionAndAnotherConversationAreIndependent() {
    var ledger = ContinuedExecutionLedger()
    let rejected = identity(), active = identity("other", conversation: "other-chat")
    XCTAssertTrue(ledger.request(rejected))
    XCTAssertTrue(ledger.request(active))
    XCTAssertTrue(ledger.activate(active))
    XCTAssertEqual(ledger.finish(rejected)?.phase, .requested)
    XCTAssertEqual(ledger.entry(conversationID: "other-chat")?.phase, .active)
  }

  func testProgressBeforeAdmissionIsRetainedAndNeverOverflows() {
    var ledger = ContinuedExecutionLedger()
    let run = identity()
    XCTAssertTrue(ledger.request(run))
    XCTAssertEqual(ledger.advance(run, by: 3)?.completedUnits, 3)
    XCTAssertTrue(ledger.activate(run))
    XCTAssertNil(ledger.advance(run, by: -1))
    XCTAssertEqual(ledger.advance(run, by: Int64.max)?.completedUnits, Int64.max - 1)
    XCTAssertEqual(ledger.advance(run)?.completedUnits, Int64.max - 1)
  }
}
