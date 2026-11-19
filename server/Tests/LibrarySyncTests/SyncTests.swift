import Foundation
import Testing
import WovenLibrary
import WovenProtocol

/// A fresh library in its own temporary folder.
private func makeLibrary(_ name: String) async throws -> Library {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-sync-\(UUID().uuidString)")
  return try await Library.open(folder: folder, machineName: name)
}

/// `into` pulls everything `from` has past its cursor, page by page.
private func sync(_ into: Library, from: Library) async throws {
  while true {
    let page = try await from.pull(after: try await into.cursor(for: from.machineID), limit: 3)
    try await into.apply(page, from: from.machineID)
    if !page.more { return }
  }
}

/// Every synced row a library holds, without the local `changed` counter.
private func contents(_ library: Library) async throws -> Set<SyncRow> {
  Set(try await library.pull(after: 0, limit: 100_000).rows)
}

@Test func threeLibrariesConvergeWhenTwoEditApartAndOneRelays() async throws {
  let a = try await makeLibrary("a"), b = try await makeLibrary("b"), relay = try await makeLibrary("relay")
  // A and B never talk to each other; everything goes through the relay.
  _ = try await a.createFolder(name: "Work", path: "/work")
  try await a.setSetting("theme", to: .string("dark"))
  _ = try await b.createSession(runtime: .codex, title: "From B")
  try await Task.sleep(for: .milliseconds(5))
  try await b.setSetting("theme", to: .string("light"))

  try await sync(relay, from: a)
  try await sync(relay, from: b)
  try await sync(a, from: relay)
  try await sync(b, from: relay)

  let expected = try await contents(relay)
  #expect(try await contents(a) == expected)
  #expect(try await contents(b) == expected)
  #expect(try await a.setting("theme")?.value == .string("light"))
  #expect(try await a.sessions().map(\.title) == ["From B"])
  #expect(try await b.folders().map(\.name) == ["Work"])
  #expect(Set(try await b.machines().map(\.id)) == [a.machineID, b.machineID, relay.machineID])
}

@Test func concurrentArtifactEditKeepsNewerCurrentAndOlderInHistoryEverywhere() async throws {
  let a = try await makeLibrary("a"), b = try await makeLibrary("b"), c = try await makeLibrary("c")
  try await a.put("artifacts", id: "note", ["kind": .text("note"), "title": .text("Plan"), "body": .text("base")])
  try await sync(b, from: a)
  // Edited apart: neither has seen the other's edit. B's is newer.
  try await a.put("artifacts", id: "note", ["body": .text("edit on a")])
  try await a.put("artifacts", id: "note", ["body": .text("second edit on a")])
  try await Task.sleep(for: .milliseconds(5))
  try await b.put("artifacts", id: "note", ["body": .text("edit on b")])

  try await sync(a, from: b)
  try await sync(b, from: a)
  try await sync(c, from: a)

  for library in [a, b, c] {
    #expect(try await library.row("artifacts", id: "note")?.values["body"] == .text("edit on b"))
    let versions = try await library.rows("artifact_versions", where: "artifact_id", is: .text("note"))
    #expect(versions.map { $0.values["body"] } == [.text("second edit on a")])
  }
  // C's own machine row reaches the others too.
  try await sync(a, from: c)
  try await sync(b, from: a)
  #expect(try await contents(a) == contents(b))
  #expect(try await contents(b) == contents(c))
}

@Test func deletionSpreadsAndIsNotResurrectedByALateEdit() async throws {
  let a = try await makeLibrary("a"), b = try await makeLibrary("b")
  let session = try await a.createSession(runtime: .codex, title: "Doomed")
  _ = try await a.appendItem(sessionID: session.id, content: .userMessage(text: "first"))
  try await sync(b, from: a)
  try await b.deleteSession(session.id)
  // A has not heard of the deletion and keeps writing, later than it.
  try await Task.sleep(for: .milliseconds(5))
  _ = try await a.updateSession(session.id, title: "Renamed later")
  _ = try await a.appendItem(sessionID: session.id, content: .userMessage(text: "late"))

  try await sync(b, from: a)
  try await sync(a, from: b)

  for library in [a, b] {
    #expect(try await library.session(session.id) == nil)
    #expect(try await library.items(sessionID: session.id).isEmpty)
    #expect(try await library.row("sessions", id: session.id)?.deleted == true)
  }
  #expect(try await contents(a) == contents(b))
}

@Test func appendOnlyRowArrivesExactlyOnceHoweverOftenItIsPulled() async throws {
  let a = try await makeLibrary("a"), b = try await makeLibrary("b"), relay = try await makeLibrary("relay")
  let session = try await a.createSession(runtime: .codex, title: "Chat")
  for text in ["one", "two", "three"] { _ = try await a.appendItem(sessionID: session.id, content: .userMessage(text: text)) }

  // The same page applied again and again, then the same rows by relay.
  let everything = try await a.pull(after: 0)
  for _ in 0..<3 { try await b.apply(everything, from: a.machineID) }
  try await sync(relay, from: a)
  try await sync(b, from: relay)
  try await sync(a, from: b)

  for library in [a, b] {
    let items = try await library.items(sessionID: session.id)
    #expect(items.map(\.sequence) == [1, 2, 3])
    #expect(items.map(\.content) == ["one", "two", "three"].map { .userMessage(text: $0) })
  }
  #expect(try await contents(a) == contents(b))
}
