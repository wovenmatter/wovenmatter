import Foundation
import Testing
import WovenLibrary
import WovenProtocol

@Test func sessionListShowsTheLastMessageAndIsUnreadOnlyAfterSomethingNotThePersonsOwn() async throws {
  let library = try await Library.open(
    folder: FileManager.default.temporaryDirectory.appendingPathComponent("woven-list-\(UUID().uuidString)"), machineName: "a")
  let session = try await library.createSession(runtime: .codex, title: "Chat")
  let start = Date()
  func listed() async throws -> Session { try #require(try await library.sessions().first { $0.id == session.id }) }

  _ = try await library.appendItem(sessionID: session.id, content: .userMessage(text: "Hello\n  there"), createdAt: start)
  #expect(try await listed().unread == false)
  #expect(try await listed().preview == "Hello there")

  _ = try await library.appendItem(sessionID: session.id, content: .assistantMessage(text: "Hi"),
                                   createdAt: start.addingTimeInterval(1))
  _ = try await library.appendItem(sessionID: session.id, content: .toolCall(ToolCall(name: "echo", input: "{}")),
                                   createdAt: start.addingTimeInterval(2))
  let answered = try await listed()
  #expect(answered.unread && answered.preview == "Hi")
  #expect(abs(answered.lastActivityAt.timeIntervalSince(start.addingTimeInterval(2))) < 0.01)

  #expect(try await library.updateSession(session.id, read: true).unread == false)
  _ = try await library.appendItem(sessionID: session.id, content: .assistantMessage(text: "More"),
                                   createdAt: start.addingTimeInterval(3))
  #expect(try await listed().unread)
}
