import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

// Pi Durable's and the bots' own stores, in Pi Durable's SQLite layout,
// read into the usage ledger. The fixtures are synthetic.

private func temporary(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A Pi Durable table set: its conversations, tasks, entries and documents.
private func tableSet(_ database: DatabaseFile, prefix: String) throws {
  _ = try database.execute("""
    CREATE TABLE \(prefix)conversations (id INTEGER PRIMARY KEY, owner_conversation_id INTEGER, owner_task_id INTEGER, record TEXT);
    CREATE TABLE \(prefix)tasks (id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, record TEXT);
    CREATE TABLE \(prefix)entries (id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, head INTEGER, commit_seq INTEGER, record TEXT);
    CREATE TABLE \(prefix)documents (id INTEGER PRIMARY KEY, kind TEXT, family INTEGER, key_value TEXT, scope_kind TEXT,
      owner_id INTEGER, created_at INTEGER, retired_at INTEGER, record TEXT);
    CREATE TABLE \(prefix)document_revisions (document_id INTEGER, seq INTEGER, kind TEXT, version INTEGER, content TEXT);
    INSERT INTO \(prefix)conversations VALUES (1, NULL, NULL, '{}');
    """)
}

private func assistant(_ entry: Int, conversation: Int = 1, at: Int64, input: Int, output: Int, response: String? = nil,
                       content: String = #"[{"type":"text","text":"Done."}]"#) -> String {
  let id = response.map { #","responseId":"\#($0)""# } ?? ""
  let record = #"{"kind":"pi.assistant","model":[{"role":"assistant","content":\#(content),"provider":"p","model":"m","usage":{"input":\#(input),"output":\#(output),"cacheRead":0,"cacheWrite":0,"totalTokens":\#(input + output),"cost":{"total":0.5}},"timestamp":\#(at)\#(id)}]}"#
  return "(\(entry), \(conversation), NULL, \(entry), '\(record)')"
}

/// The `pi.usage` document of a conversation: its sums per model.
private func usageDocument(_ database: DatabaseFile, prefix: String, conversation: Int, input: Int, output: Int) throws {
  _ = try database.execute("""
    INSERT INTO \(prefix)documents VALUES (\(10 + conversation), '"pi.usage"', 0, '""', 'conversation', \(conversation), 1, NULL, '{}');
    INSERT INTO \(prefix)document_revisions VALUES (\(10 + conversation), 5, 'base', 1,
      '{"models":{"p/m":{"input":\(input),"output":\(output),"cacheRead":0,"cacheWrite":0,"totalTokens":\(input + output),"cost":{"total":0}}},"tools":{}}');
    """)
}

private func totals(_ library: Library) async throws -> UsageReport {
  try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 86_400)
}

/// A Pi Durable store counts every assistant response once, with or without
/// a provider's identifier, a sub-agent's under its session, and what its
/// `pi.usage` sums beyond them (a compaction) as one more; all are Woven
/// Matter's, under the session the store's session is. Reading it all again
/// changes nothing.
@Test func piDurablesStoreCountsEachResponseOnce() async throws {
  let data = try temporary("pi-data")
  let url = data.appendingPathComponent("pi-durable/pi-durable.sqlite")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: url)
  let database = try DatabaseFile(url: url, isCopy: false)
  let session = "0b1c2d3e-4f50-4617-8899-aabbccddeeff"
  let prefix = "s0b1c2d3e4f5046178899aabbccddeeff_"
  try tableSet(database, prefix: prefix)
  let day = Int64(1_767_610_800_000)
  _ = try database.execute("""
    INSERT INTO \(prefix)tasks VALUES (7, 1, '{}');
    INSERT INTO \(prefix)conversations VALUES (2, NULL, 7, '{}');
    INSERT INTO \(prefix)entries VALUES \(assistant(3, at: day, input: 100, output: 10, response: "resp_a")),
      \(assistant(4, at: day + 1000, input: 50, output: 5)), \(assistant(5, conversation: 2, at: day + 2000, input: 20, output: 2));
    """)
  // Conversation 1's sums hold a compaction of 30 and 3 beyond its entries.
  try usageDocument(database, prefix: prefix, conversation: 1, input: 180, output: 18)
  try usageDocument(database, prefix: prefix, conversation: 2, input: 20, output: 2)

  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.setNativeSession("woven-1", runtime: .piDurable, handle: session)
  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.piDurable, url)])
  #expect(await scanner.scan().added == 4)
  let report = try await totals(library)
  #expect(report.totals == UsageAmounts(input: 200, output: 20, cost: 1.5, requests: 4))
  #expect(report.groups.allSatisfy { $0.runtime == .piDurable && $0.sessionID == "woven-1" && $0.inWoven && $0.model == "p/m" })
  #expect(Set(report.groups.map(\.period)) == [Date(timeIntervalSince1970: 1_767_571_200)])

  func rows() async throws -> [SyncRow] { try await library.rows("usage_hours", where: "machine_id", is: .text(library.machineID)) }
  let before = try await rows()
  for id in try await library.usageSources().keys { try await library.saveUsage([], source: UsageSource(id: id)) }
  let again = await scanner.scan()
  let after = try await rows()
  #expect(again.added == 0 && again.records == 0 && after == before)

  // A new response is read on from the place.
  _ = try database.execute("INSERT INTO \(prefix)entries VALUES \(assistant(6, at: day + 3000, input: 1, output: 1));")
  let next = await scanner.scan()
  #expect(next.found == 2 && next.added == 1)
}

private func botsStore(_ url: URL) throws -> DatabaseFile {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: url)
  let database = try DatabaseFile(url: url, isCopy: false)
  _ = try database.execute("""
    CREATE TABLE bot_bots (id TEXT PRIMARY KEY, name TEXT, schema_prefix TEXT, created_at TEXT, deleted_at TEXT);
    CREATE TABLE bot_forum_seat_conversations (conversation_id INTEGER, bot_id TEXT, room_id INTEGER);
    CREATE TABLE bot_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, bot_id TEXT, conversation_id INTEGER, purpose TEXT,
      created_at INTEGER, provider TEXT, model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
      cost REAL, response_id TEXT);
    INSERT INTO bot_bots VALUES ('b1', 'Ada', 'bot_b1_', '', NULL);
    INSERT INTO bot_forum_seat_conversations VALUES (5, 'b1', 1);
    """)
  try tableSet(database, prefix: "bot_b1_")
  return database
}

private func botUsage(_ database: DatabaseFile, bot: String, conversation: Int, purpose: String, at: Int64, input: Int) throws {
  _ = try database.execute("""
    INSERT INTO bot_usage (bot_id, conversation_id, purpose, created_at, provider, model, input, output, cache_read, cache_write, cost)
    VALUES ('\(bot)', \(conversation), '\(purpose)', \(at), 'p', 'm', \(input), 1, 0, 0, 0);
    """)
}

/// The bots' store counts every response in it once: a reply with nothing
/// to show, one in a thread since deleted, a seat's under its Forum room,
/// and each title, memory extraction and compaction call. A chat saved
/// after its usage was read takes it under its session.
@Test func theBotsStoreCountsEveryModelCallOnce() async throws {
  let data = try temporary("bots-data")
  let url = data.appendingPathComponent("bots/bots.sqlite")
  let database = try botsStore(url)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.setSetting(botsHostSetting, to: .string(library.machineID))
  let at = Int64((Date().timeIntervalSince1970 + 60) * 1000)
  _ = try database.execute("""
    INSERT INTO bot_b1_conversations VALUES (3, NULL, NULL, '{}'), (5, NULL, NULL, '{}');
    INSERT INTO bot_b1_entries VALUES \(assistant(10, at: at, input: 10, output: 1, response: "resp_1")),
      \(assistant(11, at: at, input: 20, output: 1, content: "[]")),
      \(assistant(12, conversation: 3, at: at, input: 30, output: 1)), \(assistant(13, conversation: 5, at: at, input: 40, output: 1));
    """)
  try botUsage(database, bot: "b1", conversation: 3, purpose: "title", at: at, input: 5)
  try botUsage(database, bot: "b1", conversation: 1, purpose: "memory", at: at, input: 6)
  try botUsage(database, bot: "b1", conversation: 1, purpose: "compaction", at: at, input: 7)
  try botUsage(database, bot: "", conversation: 1, purpose: "title", at: at, input: 8)

  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.bots, url)])
  #expect(await scanner.scan().added == 8)
  #expect(await scanner.scan().added == 0)
  var report = try await totals(library)
  #expect(report.totals.requests == 8 && report.totals.input == 126)
  let sessions = Dictionary(grouping: report.groups, by: { $0.nativeSessionID ?? "" }).mapValues { $0.reduce(0) { $0 + $1.amounts.requests } }
  #expect(sessions == ["b1/1": 4, "b1/3": 2, "forum/1": 2])

  try await library.saveBotMirror(BotMirror(
    bot: BotMirror.Bot(id: "b1", name: "Ada", isAdmin: false, manager: false, managerID: nil, orchestrator: false, trashed: false,
                       createdAt: Date()),
    chats: [BotMirror.Chat(sessionID: "chat-1", botID: "b1", conversationID: 1, kind: .main, parentConversationID: nil,
                           title: "Ada", pinned: false, createdAt: Date())],
    items: [], checkpoint: "bot:b1", upTo: 0))
  report = try await totals(library)
  #expect(report.groups.filter { $0.nativeSessionID == "b1/1" }.allSatisfy { $0.sessionID == "chat-1" && $0.inWoven })
}

/// Bots that move to another machine take their store with them; the new
/// host counts only what they do after it became their host, so nothing is
/// counted on both.
@Test func movedBotsAreCountedOnceAcrossTheirHosts() async throws {
  let data = try temporary("bots-data")
  let url = data.appendingPathComponent("bots/bots.sqlite")
  let database = try botsStore(url)
  let old = try await Library.open(folder: try temporary("usage-library"), machineName: "old")
  try await old.setSetting(botsHostSetting, to: .string(old.machineID))
  let before = Int64((Date().timeIntervalSince1970 + 1) * 1000)
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES \(assistant(10, at: before, input: 10, output: 1));")
  await UsageScanner(library: old, home: try temporary("usage-home"), stores: [(.bots, url)]).readStores(.bots)
  #expect(try await totals(old).totals.requests == 1)

  try await Task.sleep(for: .milliseconds(1100))
  let new = try await Library.open(folder: try temporary("usage-library"), machineName: "new")
  try await new.setSetting(botsHostSetting, to: .string(new.machineID))
  let scanner = UsageScanner(library: new, home: try temporary("usage-home"), stores: [(.bots, url)])
  #expect(await scanner.scan().added == 0)
  let after = Int64((Date().timeIntervalSince1970 + 1) * 1000)
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES \(assistant(11, at: after, input: 20, output: 1));")
  #expect(await scanner.scan().added == 1)
  #expect(try await totals(new).totals.input == 20)
}
