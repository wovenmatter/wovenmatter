import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// Every harness and Pi Durable location on a Mac, and the rules that keep one reply,
/// one turn and one device from counting twice.
@Suite("Usage from every source, counted once")
struct UsageEverySourceTests {
  private static let now = Date()
  private static let milliseconds = Int64((now.timeIntervalSince1970 - 3_600) * 1_000)

  private func write(_ lines: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try lines.map { try JSONSerialization.data(withJSONObject: $0) }
    try (data.reduce(Data()) { $0 + $1 + Data("\n".utf8) }).write(to: url)
  }

  private func reply(_ offset: Int64, input: Int, provider: String = "openai-codex", model: String = "gpt-5.5") -> [String: Any] {
    ["role": "assistant", "provider": provider, "model": model, "timestamp": Self.milliseconds + offset, "content": "private reply",
     "usage": ["input": input, "output": 2, "cacheRead": 3, "cacheWrite": 0, "totalTokens": input + 5]]
  }

  private func entry(_ id: Int, conversation: Int, _ messages: [String: Any]...) -> [String: Any] {
    ["id": id, "conversationId": conversation, "kind": "pi.assistant", "model": [["role": "user", "content": "private question"]] + messages]
  }

  private func database(_ url: URL, _ statements: [String], rows: [(table: String, id: Int, conversation: Int, record: [String: Any])] = []) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    defer { sqlite3_close(handle) }
    for statement in statements { #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK) }
    for row in rows {
      let json = String(decoding: try JSONSerialization.data(withJSONObject: row.record), as: UTF8.self)
        .replacingOccurrences(of: "'", with: "''")
      #expect(sqlite3_exec(handle, "INSERT INTO \"\(row.table)\" VALUES (\(row.id), \(row.conversation), NULL, 1, '\(json)')", nil, nil, nil) == SQLITE_OK)
    }
  }

  private static let entriesTable = "(id INTEGER PRIMARY KEY, conversation_id INTEGER NOT NULL, head INTEGER, commit_seq INTEGER NOT NULL, record TEXT NOT NULL)"

  private func codexRollout(session: String) -> [[String: Any]] {
    let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3_000))
    return [
      ["type": "session_meta", "timestamp": stamp, "payload": ["id": session, "cwd": "/work/app", "originator": "codex_cli"]],
      ["type": "turn_context", "payload": ["model": "gpt-5.5"]],
      ["type": "event_msg", "timestamp": stamp, "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 100, "output_tokens": 10, "total_tokens": 110]]]],
    ]
  }

  private func service(home: URL, library: URL) -> LocalUsageService {
    LocalUsageService(
      homeDirectory: home,
      fileManager: .default,
      credentialStore: UsageNoCredentials(recordsAccess: true),
      usageDatabaseURL: library,
      sharedConnectionRevision: { 0 },
      importPreparationWorker: DatabaseWorker(label: "usage.import.every-source.fixture", capacity: 8)
    )
  }

  @Test("archived Codex chats, Pi sessions, Pi Durable in every format and bots each count once")
  func everySourceOnce() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "usage-every-source-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    let library = home.appending(path: "Support/workspace.sqlite")

    // A rollout Codex archived, with a copy left behind, and one only in the archive.
    try write(codexRollout(session: "codex-a"), to: home.appending(path: ".codex/sessions/2026/11/rollout-a.jsonl"))
    try write(codexRollout(session: "codex-a"), to: home.appending(path: ".codex/archived_sessions/rollout-a.jsonl"))
    try write(codexRollout(session: "codex-b"), to: home.appending(path: ".codex/archived_sessions/rollout-b.jsonl"))

    let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-2_000))
    try write([
      ["type": "session", "id": "pi-cli", "cwd": "/work/project"],
      ["type": "model_change", "provider": "anthropic", "modelId": "claude-opus-4-8"],
      ["type": "message", "timestamp": stamp, "message": ["role": "assistant", "id": "r1", "content": "private", "usage": ["input": 10, "output": 4, "totalTokens": 14]]],
    ], to: home.appending(path: ".pi/agent/sessions/--work--/session.jsonl"))

    let agent = home.appending(path: ".wovenmatter/default-agent")
    // Before Pi Durable, the default agent used Pi's session files.
    try write([
      ["type": "session", "id": "durable-old"],
      ["type": "message", "timestamp": stamp, "message": ["role": "assistant", "provider": "xai", "model": "grok-5", "usage": ["input": 7, "output": 1, "totalTokens": 8]]],
    ], to: agent.appending(path: "sessions/old.jsonl"))
    // A session that moved into SQLite keeps its commit log: one reply in both places.
    try write([["format": 1, "seq": 1, "type": "commit", "writes": [["type": "entry", "value": entry(2, conversation: 1, reply(0, input: 100))]]]],
              to: agent.appending(path: "durable/durable-1/native/main.jsonl"))
    try write([["format": 1, "seq": 1, "type": "commit", "writes": [["type": "entry", "value": entry(2, conversation: 1, reply(60_000, input: 40))]]]],
              to: agent.appending(path: "durable/durable-2/native/main.jsonl"))
    let store = "wm_pi_" + String(repeating: "a", count: 32) + "_"
    try database(library, [
      "CREATE TABLE wm_pi_runtime_stores (store_id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, schema_prefix TEXT NOT NULL UNIQUE, format INTEGER NOT NULL, activated_at TEXT NOT NULL)",
      "INSERT INTO wm_pi_runtime_stores VALUES ('s1', 'durable-1', '\(store)', 1, '2026-10-28T00:00:00Z')",
      "CREATE TABLE \"\(store)entries\" \(Self.entriesTable)",
    ], rows: [(store + "entries", 2, 1, entry(2, conversation: 1, reply(0, input: 100)))])
    // Bots keep their own database beside the library; each conversation is a session.
    let bot = "pibot_" + String(repeating: "b", count: 32) + "_"
    try database(library.deletingLastPathComponent().appending(path: "Bots/data/bots.sqlite"), [
      "CREATE TABLE pibot_bots (id TEXT PRIMARY KEY, name TEXT NOT NULL, schema_prefix TEXT NOT NULL UNIQUE)",
      "INSERT INTO pibot_bots VALUES ('bot-1', 'Scout', '\(bot)')",
      "CREATE TABLE \"\(bot)entries\" \(Self.entriesTable)",
    ], rows: [
      (bot + "entries", 1, 1, entry(1, conversation: 1, reply(120_000, input: 30, provider: "openrouter", model: "kimi-k2"))),
      (bot + "entries", 2, 7, entry(2, conversation: 7, reply(180_000, input: 20, provider: "openrouter", model: "kimi-k2"))),
    ])

    let usage = service(home: home, library: library)
    let snapshot = try await usage.analyticsSnapshot(range: .allTime, refreshReason: .startup, now: Self.now)
    func total(_ samples: [UsageSample]) -> Int64 { samples.reduce(0) { $0 + $1.tokens.totalTokens } }
    #expect(total(snapshot.samples.filter { $0.harness == "Codex" }) == 220)
    let piCLI = snapshot.samples.filter { $0.harness == "Pi" }
    #expect(total(piCLI) == 14)
    #expect(piCLI.first?.provider == .claude)
    let durable = snapshot.samples.filter { $0.harness == "Pi Durable" }
    #expect(total(durable.filter { $0.sessionID == "durable-1" }) == 105)
    #expect(total(durable.filter { $0.sessionID == "durable-2" }) == 45)
    #expect(total(durable.filter { $0.sessionID == "durable-old" }) == 8)
    let bots = durable.filter { $0.agent == "Scout" }
    #expect(Set(bots.map(\.sessionID)) == ["bot:bot-1:1", "bot:bot-1:7"])
    #expect(total(bots) == 60)
    #expect(durable.allSatisfy { $0.application == "Woven Matter" })
    let listed = Set(snapshot.sources.map(\.id))
    #expect(listed.isSuperset(of: ["codex", "pi", "pi-durable"]))

    // A purged bot's tables are gone, but its usage already happened.
    try database(library.deletingLastPathComponent().appending(path: "Bots/data/bots.sqlite"), [
      "DELETE FROM pibot_bots", "DROP TABLE \"\(bot)entries\"",
    ])
    let later = try await usage.analyticsSnapshot(range: .allTime, refreshReason: .manual, now: Self.now.addingTimeInterval(1))
    #expect(total(later.samples.filter { $0.agent == "Scout" }) == 60)
    #expect(total(later.samples) == total(snapshot.samples))
  }

  private func sample(_ id: String, harness: String, session: String, minutesAgo: Double, tokens: Int64,
                      source: String, provider: ProviderKind = .codex) -> UsageSample {
    UsageSample(id: id, provider: provider, timestamp: Self.now.addingTimeInterval(-minutesAgo * 60), sessionID: session,
                accountLabel: "a", model: "gpt-5.5", harness: harness, application: "app",
                tokens: UsageTokenCounts(inputTokens: tokens), sourceID: source)
  }

  @Test("a turn Woven watched goes once the harness's own history has it, under any session ID")
  func liveRunsGiveWayToHistory() {
    let live = "wovenmatter:local"
    let kept = LocalUsageService.suppressWovenMatterEchoes([
      // Same session in the history.
      sample("same-session", harness: "Codex", session: "s1", minutesAgo: 0, tokens: 500, source: live),
      sample("history-1", harness: "Codex", session: "s1", minutesAgo: 120, tokens: 1, source: "codex:file:a"),
      // Another session ID (a Woven durable session), with the turn's calls split up shortly before.
      sample("other-session", harness: "Codex", session: "woven-7", minutesAgo: 200, tokens: 500, source: live),
      sample("history-2", harness: "Codex", session: "rollout-7", minutesAgo: 210, tokens: 200, source: "codex:file:b"),
      sample("history-3", harness: "Codex", session: "rollout-7", minutesAgo: 205, tokens: 300, source: "codex:file:b"),
      // Pi Durable's live copy and its store.
      sample("durable-live", harness: "Pi Durable", session: "d1", minutesAgo: 300, tokens: 50, source: live),
      sample("durable-store", harness: "Pi Durable", session: "d1", minutesAgo: 301, tokens: 50, source: "pi-durable:database:x"),
      // Nothing in any history yet: the live copy stands.
      sample("unseen", harness: "Claude Code", session: "c9", minutesAgo: 400, tokens: 70, source: live, provider: .claude),
      // History in this harness long before the turn doesn't count as having it.
      sample("old-history", harness: "Claude Code", session: "c1", minutesAgo: 500, tokens: 5, source: "claude:file:a", provider: .claude),
    ])
    #expect(Set(kept.map(\.id)) == ["history-1", "history-2", "history-3", "durable-store", "unseen", "old-history"])
  }

  @Test("rows saved under the Built-in harness read as Pi Durable")
  func builtInIsPiDurable() {
    #expect(UsageSample.currentHarnessName("Built-in") == "Pi Durable")
    #expect(UsageSample.currentHarnessName("Codex") == "Codex")
  }

  @Test("a host's earlier device ID reads as the host, keeping only sessions the host no longer reports")
  func deviceAliases() {
    let host = "8f5c2a", workspace = "0d6f8e4a-0000-4000-8000-000000000000"
    let old = UsageDeviceSource.sourceID(deviceID: workspace), current = UsageDeviceSource.sourceID(deviceID: host)
    let resolved = UsageSample.resolvingDeviceAliases([
      sample("reported", harness: "Codex", session: "s1", minutesAgo: 10, tokens: 10, source: current),
      // The host still reports this session: the earlier copy goes.
      sample("old-copy", harness: "Codex", session: "s1", minutesAgo: 10, tokens: 10, source: old),
      // Only the earlier copy has this one (its transcript is gone from the host).
      sample("only-old", harness: "Claude Code", session: "s2", minutesAgo: 900, tokens: 4, source: old, provider: .claude),
      // A turn this Mac watched there moves with the device.
      sample("watched", harness: "Codex", session: "w", minutesAgo: 5, tokens: 3, source: UsageDeviceSource.liveRunsSourceID(deviceID: workspace)),
      sample("this-mac", harness: "Codex", session: "m", minutesAgo: 5, tokens: 3, source: "codex:file:z"),
    ], aliases: [workspace: host])
    #expect(Set(resolved.map(\.id)) == ["reported", "only-old", "watched", "this-mac"])
    #expect(resolved.first { $0.id == "only-old" }?.usageDeviceID == host)
    #expect(resolved.first { $0.id == "watched" }?.sourceID == UsageDeviceSource.liveRunsSourceID(deviceID: host))
    #expect(resolved.first { $0.id == "this-mac" }?.usageDeviceID == UsageDeviceSource.localDeviceID)
  }
}
