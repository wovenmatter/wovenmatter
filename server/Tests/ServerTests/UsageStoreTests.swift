import Foundation
import Synchronization
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
private func usageDocument(_ database: DatabaseFile, prefix: String, conversation: Int, input: Int, output: Int, cost: Double = 0) throws {
  _ = try database.execute("""
    INSERT INTO \(prefix)documents VALUES (\(10 + conversation), '"pi.usage"', 0, '""', 'conversation', \(conversation), 1, NULL, '{}');
    INSERT INTO \(prefix)document_revisions VALUES (\(10 + conversation), 5, 'base', 1,
      '{"models":{"p/m":{"input":\(input),"output":\(output),"cacheRead":0,"cacheWrite":0,"totalTokens":\(input + output),"cost":{"total":\(cost)}}},"tools":{}}');
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
  // Conversation 1's sums hold a compaction of 30 and 3 tokens and $1 beyond its entries, made the next day.
  let compaction = #"{"kind":"pi.compaction","model":[{"role":"user","content":"summary","timestamp":\#(day + 86_400_000)}]}"#
  _ = try database.execute("INSERT INTO \(prefix)entries VALUES (8, 1, NULL, 8, '\(compaction)');")
  try usageDocument(database, prefix: prefix, conversation: 1, input: 180, output: 18, cost: 2)
  try usageDocument(database, prefix: prefix, conversation: 2, input: 20, output: 2, cost: 0.5)

  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.setNativeSession("woven-1", runtime: .piDurable, handle: session)
  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.piDurable, url)])
  #expect(await scanner.scan().added == 4)
  let report = try await totals(library)
  #expect(report.totals == UsageAmounts(input: 200, output: 20, cost: 2.5, requests: 4))
  #expect(report.groups.allSatisfy { $0.runtime == .piDurable && $0.sessionID == "woven-1" && $0.inWoven && $0.model == "p/m" })
  #expect(report.groups.map { ($0.period.timeIntervalSince1970, $0.amounts.requests) }.sorted { $0.0 < $1.0 }.map(\.1) == [3, 1])

  func rows() async throws -> [SyncRow] { try await library.rows("usage_hours", where: "machine_id", is: .text(library.machineID)) }
  let before = try await rows()
  for id in try await library.usageSources().keys { try await library.saveUsage([], source: UsageSource(id: id)) }
  let again = await scanner.scan()
  let after = try await rows()
  #expect(again.added == 0 && again.records == 0 && after == before)

  // A new response is read on from the place.
  _ = try database.execute("INSERT INTO \(prefix)entries VALUES \(assistant(9, at: day + 3000, input: 1, output: 1));")
  // Only a changed usage document is reconciled again: this one was not.
  let next = await scanner.scan()
  #expect(next.found == 1 && next.added == 1)
}

private func botsStore(_ url: URL) throws -> DatabaseFile {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: url)
  let database = try DatabaseFile(url: url, isCopy: false)
  _ = try database.execute("""
    CREATE TABLE bot_bots (id TEXT PRIMARY KEY, name TEXT, schema_prefix TEXT, created_at TEXT, deleted_at TEXT);
    CREATE TABLE bot_forum_seat_conversations (conversation_id INTEGER, bot_id TEXT, room_id INTEGER);
    CREATE TABLE bot_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, call_id TEXT UNIQUE, bot_id TEXT, conversation_id INTEGER, purpose TEXT,
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
    INSERT INTO bot_usage (call_id, bot_id, conversation_id, purpose, created_at, provider, model, input, output, cache_read,
      cache_write, cost) VALUES ('\(UUID().uuidString)', '\(bot)', \(conversation), '\(purpose)', \(at), 'p', 'm', \(input), 1, 0, 0, 0);
    """)
}

/// The bots' store counts every response in it once: a reply with nothing
/// to show, one in a thread since deleted, a seat's under its Forum room
/// (its compaction too), and each title, memory extraction and compaction
/// call. A chat saved
/// after its usage was read takes it under its session.
@Test func theBotsStoreCountsEveryModelCallOnce() async throws {
  let data = try temporary("bots-data")
  let url = data.appendingPathComponent("bots/bots.sqlite")
  let database = try botsStore(url)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let at = Int64(1_767_610_800_000)
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
  // A seat's compaction goes under its room, as its replies do.
  try botUsage(database, bot: "b1", conversation: 5, purpose: "compaction", at: at, input: 9)

  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.bots, url)])
  #expect(await scanner.scan().added == 9)
  #expect(await scanner.scan().added == 0)
  var report = try await totals(library)
  #expect(report.totals.requests == 9 && report.totals.input == 135)
  let sessions = Dictionary(grouping: report.groups, by: { $0.nativeSessionID ?? "" }).mapValues { $0.reduce(0) { $0 + $1.amounts.requests } }
  #expect(sessions == ["b1/1": 4, "b1/3": 2, "forum/1": 3])

  try await library.saveBotMirror(BotMirror(
    bot: BotMirror.Bot(id: "b1", name: "Ada", isAdmin: false, manager: false, managerID: nil, orchestrator: false, trashed: false,
                       createdAt: Date()),
    chats: [BotMirror.Chat(sessionID: "chat-1", botID: "b1", conversationID: 1, kind: .main, parentConversationID: nil,
                           title: "Ada", pinned: false, createdAt: Date())],
    items: [], checkpoint: "bot:b1", upTo: 0))
  report = try await totals(library)
  #expect(report.groups.filter { $0.nativeSessionID == "b1/1" }.allSatisfy { $0.sessionID == "chat-1" && $0.inWoven })
}

/// Bots that move to another machine take their store with them and the
/// place the old host had read it to: the new host counts only what lies
/// after it, also a reply written after the old host's last read. A move
/// that fails leaves the old host's place as it was.
@Test func movedBotsAreCountedOnceAcrossTheirHosts() async throws {
  let url = try temporary("bots-data").appendingPathComponent("bots/bots.sqlite")
  let database = try botsStore(url)
  let at = Int64(1_767_610_800_000)
  let old = try await Library.open(folder: try temporary("usage-library"), machineName: "old")
  let oldScanner = UsageScanner(library: old, home: try temporary("usage-home"), stores: [(.bots, url)])
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES \(assistant(10, at: at, input: 10, output: 1));")
  await oldScanner.scan()
  // Written after the old host's last read, before the move.
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES \(assistant(11, at: at, input: 20, output: 1));")
  let place = await oldScanner.botsPlace()
  #expect(place != nil)

  // The store reaches the new host at another path, after its place.
  let moved = try temporary("bots-moved").appendingPathComponent("bots/bots.sqlite")
  let new = try await Library.open(folder: try temporary("usage-library"), machineName: "new")
  let newScanner = UsageScanner(library: new, home: try temporary("usage-home"), stores: [(.bots, moved)])
  try await newScanner.installBotsPlace(place)
  try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
  for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
    try FileManager.default.copyItem(atPath: url.path + suffix, toPath: moved.path + suffix)
  }
  #expect(await newScanner.scan().added == 1)
  let newInput = try await totals(new).totals.input, oldInput = try await totals(old).totals.input
  #expect(newInput == 20 && oldInput == 10)

  // Had the move failed, the old host reads on from where it was.
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES \(assistant(12, at: at, input: 30, output: 1));")
  #expect(await oldScanner.scan().added == 2)
  #expect(try await totals(old).totals.input == 60)
}

/// Pi Durable saves each of its summariser's calls in the store, counted at
/// its own time; what a conversation's `pi.usage` sums beyond its entries
/// is reduced by them, leaving only what no saved call covers, and what is
/// left of the cost alone counts too.
@Test func piDurablesSummaryCallsAreCountedOnce() async throws {
  let url = try temporary("pi-data").appendingPathComponent("pi-durable/pi-durable.sqlite")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: url)
  let database = try DatabaseFile(url: url, isCopy: false)
  let session = "0b1c2d3e-4f50-4617-8899-aabbccddeeff"
  let prefix = "s0b1c2d3e4f5046178899aabbccddeeff_"
  try tableSet(database, prefix: prefix)
  let day = Int64(1_767_610_800_000)
  _ = try database.execute("""
    CREATE TABLE woven_usage (call_id TEXT PRIMARY KEY, session TEXT NOT NULL, created_at INTEGER NOT NULL, provider TEXT NOT NULL,
      model TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
      cost REAL NOT NULL) STRICT;
    INSERT INTO \(prefix)entries VALUES \(assistant(3, at: day, input: 100, output: 10));
    INSERT INTO woven_usage VALUES ('c1', '\(session)', \(day + 86_400_000), 'p', 'm', 30, 3, 0, 0, 0.25),
      ('c2', '\(session)', \(day + 2 * 86_400_000), 'p', 'm', 40, 4, 0, 0, 0.25);
    """)
  let compaction = #"{"kind":"pi.compaction","model":[{"role":"user","content":"summary","timestamp":\#(day + 2 * 86_400_000)}]}"#
  _ = try database.execute("INSERT INTO \(prefix)entries VALUES (8, 1, NULL, 8, '\(compaction)');")
  // The sums hold both calls, and a cost of $1 more no saved call covers.
  try usageDocument(database, prefix: prefix, conversation: 1, input: 170, output: 17, cost: 2)

  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.piDurable, url)])
  #expect(await scanner.scan().added == 4)
  let report = try await totals(library)
  #expect(report.totals == UsageAmounts(input: 170, output: 17, cost: 2, requests: 4))
  #expect(report.groups.map(\.period.timeIntervalSince1970).sorted()
    == [day / 1000, day / 1000 + 86_400, day / 1000 + 2 * 86_400].map { Double($0 - $0 % 86_400) })
  #expect(await scanner.scan().added == 0)
}

/// A large store is read a page at a time, each saved with its place, and a
/// pass whose time is up ends between pages; every response counts once.
@Test func aLargeStoreIsReadAPageAtATime() async throws {
  let url = try temporary("bots-data").appendingPathComponent("bots/bots.sqlite")
  let database = try botsStore(url)
  let at = Int64(1_767_610_800_000)
  _ = try database.execute("INSERT INTO bot_b1_entries VALUES "
    + (10..<40).map { assistant($0, at: at, input: 1, output: 1) }.joined(separator: ", ") + ";")
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let ticks = Mutex(0)
  let scanner = UsageScanner(library: library, home: try temporary("usage-home"), stores: [(.bots, url)], storePage: 4,
                             slice: .seconds(3), clock: { ticks.withLock { $0 += 1; return .seconds($0) } })
  let first = await scanner.scan()
  #expect(first.left == 1 && first.added > 0 && first.added < 30)
  var passes = 1
  while passes < 20, await scanner.scan().left > 0 { passes += 1 }
  #expect(try await totals(library).totals.requests == 30)
}
