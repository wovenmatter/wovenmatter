import XCTest
import WovenMatterShared
@testable import LibraryClient

final class PendingSendTests: XCTestCase {
  private let id = "conversation"
  private func user(_ messageID: String, _ text: String, run: String? = nil) -> LibraryMessage {
    .init(id: messageID, conversationID: id, runID: run, role: "user", content: text)
  }

  /// The message shows at once and exactly once: the local copy until the
  /// workspace's transcript has it, then the workspace's.
  func testMessageShowsOnceUntilTheWorkspaceShowsItAndItsTurn() {
    let earlier = LibraryTranscript(conversationID: id, messages: [
      user("hello", "Hey", run: "run-1"),
      .init(id: "reply", conversationID: id, runID: "run-1", role: "assistant", content: "Hi", status: "completed")
    ], runs: [.init(id: "run-1", status: "completed")])
    var pending = PendingSend(text: "What's next?", transcript: earlier)
    XCTAssertEqual(pending.phase, .sending)
    let shown = pending.displayed(in: earlier, conversationID: id)
    XCTAssertEqual(shown.messages.map(\.content), ["Hey", "Hi", "What's next?"])
    XCTAssertEqual(shown.messages.last?.role, "user")
    XCTAssertFalse(pending.isFinished(in: earlier))

    // Accepted; the workspace shows the message before its turn starts.
    pending.phase = .starting
    var arrived = earlier
    arrived.messages.append(user("server-copy", "What's next?", run: "run-2"))
    XCTAssertTrue(pending.isShown(in: arrived))
    XCTAssertEqual(pending.displayed(in: arrived, conversationID: id).messages.filter { $0.content == "What's next?" }.count, 1)
    XCTAssertFalse(pending.hasStarted(in: arrived), "Progress continues until the turn appears")

    var running = arrived
    running.activeRunID = "run-2"
    XCTAssertTrue(pending.hasStarted(in: running))
    var replied = arrived
    replied.messages.append(.init(id: "reply-2", conversationID: id, runID: "run-2", role: "assistant", content: "Plan", status: "completed"))
    XCTAssertTrue(pending.isFinished(in: replied))
  }

  /// A new chat has no transcript yet; an accepted message stops showing
  /// progress after the timeout even if no turn appears.
  func testNewChatAndTimeout() {
    let sentAt = Date(timeIntervalSince1970: 1_000)
    var pending = PendingSend(text: "Start here", transcript: nil, sentAt: sentAt)
    XCTAssertEqual(pending.displayed(in: nil, conversationID: "new-chat").messages.map(\.content), ["Start here"])
    let later = sentAt.addingTimeInterval(PendingSend.timeout + 1)
    XCTAssertFalse(pending.isFinished(in: nil, now: later), "A message still being sent waits for its answer")
    pending.phase = .starting
    XCTAssertFalse(pending.isFinished(in: nil, now: sentAt.addingTimeInterval(5)))
    XCTAssertTrue(pending.isFinished(in: nil, now: later))
  }
}
