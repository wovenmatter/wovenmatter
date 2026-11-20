import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

// Usage read from each harness's own history, in the format its CLI writes.
// The fixtures are synthetic.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("UsageFixtures")
private let rollout = "rollout-2026-01-05T10-00-00-0000aaaa-0000-7000-8000-000000000001.jsonl"
private let claudeSession = "11111111-2222-4333-8444-555555555555"

private func temporary(_ name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("woven-\(name)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func write(_ lines: [String], to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
}

private func claudeLine(_ id: String, session: String = claudeSession, model: String = "claude-example", at: String,
                        input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
  #"{"type":"assistant","sessionId":"\#(session)","timestamp":"\#(at)","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"Synthetic."}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
}

private func totals(_ library: Library) async throws -> [RuntimeKind: UsageAmounts] {
  let report = try await library.usage(from: Date(timeIntervalSince1970: 0), to: Date().addingTimeInterval(86_400 * 400),
                                       periodSeconds: 86_400)
  var sums: [RuntimeKind: UsageAmounts] = [:]
  for group in report.groups {
    var sum = sums[group.runtime] ?? UsageAmounts()
    sum.input += group.amounts.input
    sum.output += group.amounts.output
    sum.cacheRead += group.amounts.cacheRead
    sum.cacheWrite += group.amounts.cacheWrite
    sum.cost += group.amounts.cost
    sum.requests += group.amounts.requests
    sums[group.runtime] = sum
  }
  return sums
}

/// Codex, Claude Code, Grok Build, the Pi CLI and OpenCode are each read
/// from their own history; copies from other sessions and repeated lines
/// count once, a second pass adds nothing, Codex compressing a file it was
/// writing adds nothing, and a new line is the only thing read next time.
@Test func everyHarnessHistoryCountsOnceAndARescanAddsNothing() async throws {
  let home = try temporary("usage-home")
  let codex = home.appendingPathComponent(".codex/sessions/2026/01/05/" + rollout)
  try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixtures.appendingPathComponent(rollout), to: codex)

  let project = home.appendingPathComponent(".claude/projects/-tmp-example")
  let claude = project.appendingPathComponent(claudeSession + ".jsonl")
  try write([
    #"{"type":"user","sessionId":"\#(claudeSession)","timestamp":"2026-01-05T11:00:00.000Z","message":{"role":"user","content":"Hello"}}"#,
    // One message written as two lines, one per content block.
    claudeLine("msg_one", at: "2026-01-05T11:00:01.000Z", input: 3, output: 20, cacheRead: 100, cacheWrite: 50),
    claudeLine("msg_one", at: "2026-01-05T11:00:01.500Z", input: 3, output: 20, cacheRead: 100, cacheWrite: 50),
    // Copied from the session this one was resumed from.
    claudeLine("msg_copied", session: "99999999-2222-4333-8444-555555555555", at: "2026-01-04T09:00:00.000Z", input: 500, output: 500),
    claudeLine("msg_synthetic", model: "<synthetic>", at: "2026-01-05T11:00:02.000Z", input: 0, output: 0),
  ], to: claude)
  try write([claudeLine("msg_agent", at: "2026-01-05T11:00:03.000Z", input: 1, output: 2)],
            to: project.appendingPathComponent(claudeSession + "/subagents/agent-a1.jsonl"))

  let grokSession = "0193aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee"
  let grok = home.appendingPathComponent(".grok/sessions/%2Ftmp%2Fexample/" + grokSession)
  try write([#"{"current_model_id":"grok-example","info":{"id":"\#(grokSession)"}}"#], to: grok.appendingPathComponent("summary.json"))
  try write([
    #"{"timestamp":1767610800,"timestamp_us":1767610800000000,"method":"session/update","params":{"sessionId":"\#(grokSession)","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Synthetic."}},"_meta":{"eventId":"\#(grokSession)-1"}}}"#,
    #"{"timestamp":1767610801,"timestamp_us":1767610801000000,"method":"_x.ai/session/update","params":{"sessionId":"\#(grokSession)","update":{"sessionUpdate":"usage","usage":{"inputTokens":100,"cachedReadTokens":40,"outputTokens":7,"totalTokens":107,"costUsdTicks":25000000000}},"_meta":{"eventId":"\#(grokSession)-2"}}}"#,
  ], to: grok.appendingPathComponent("updates.jsonl"))

  try write([
    #"{"type":"session","version":3,"id":"pi-session-1","timestamp":"2026-01-05T12:00:00.000Z","cwd":"/tmp/example"}"#,
    #"{"type":"model_change","id":"e1","parentId":null,"timestamp":"2026-01-05T12:00:00.100Z","provider":"anthropic","modelId":"claude-example"}"#,
    #"{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-05T12:00:05.000Z","message":{"role":"assistant","content":[],"provider":"anthropic","model":"claude-example","responseId":"msg_pi_1","usage":{"input":11,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":16,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0.01}},"stopReason":"stop"}}"#,
  ], to: home.appendingPathComponent(".pi/agent/sessions/--tmp-example--/2026-01-05T12-00-00-000Z_pi-session-1.jsonl"))

  let openCode = home.appendingPathComponent(".local/share/opencode/opencode.db")
  try FileManager.default.createDirectory(at: openCode.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: openCode)
  _ = try DatabaseFile(url: openCode, isCopy: false).execute("""
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER,
      time_updated INTEGER, data TEXT);
    INSERT INTO session_v2 VALUES ('ses_parent', NULL), ('ses_child', 'ses_parent');
    INSERT INTO session_message VALUES
      ('msg_a', 'ses_child', 'assistant', 1, 1767614400000, 1767614401000,
       '{"tokens":{"input":9,"output":4,"reasoning":2,"cache":{"read":1,"write":0}},"cost":0.002,"model":{"id":"kimi-example","providerID":"opencode-go"},"time":{"created":1767614400000,"completed":1767614401000}}'),
      ('msg_b', 'ses_parent', 'assistant', 2, 1767614402000, 1767614402000,
       '{"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0,"model":{"id":"kimi-example","providerID":"opencode-go"},"time":{"created":1767614402000}}'),
      ('msg_c', 'ses_parent', 'user', 3, 1767614403000, 1767614403000, '{}');
    """)

  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  let first = await scanner.scan()
  #expect(first.added == 30 + 2 + 1 + 1 + 1)
  let counted = try await totals(library)
  #expect(counted[.codex] == UsageAmounts(input: 6435, output: 735, cacheRead: 24000, requests: 30))
  #expect(counted[.claudeCode] == UsageAmounts(input: 4, output: 22, cacheRead: 100, cacheWrite: 50, requests: 2))
  #expect(counted[.grokBuild] == UsageAmounts(input: 60, output: 7, cacheRead: 40, cost: 2.5, requests: 1))
  #expect(counted[.piCLI] == UsageAmounts(input: 11, output: 5, cost: 0.01, requests: 1))
  #expect(counted[.openCode] == UsageAmounts(input: 9, output: 6, cacheRead: 1, cost: 0.002, requests: 1))
  let groups = try await library.usage(from: Date(timeIntervalSince1970: 0), to: Date().addingTimeInterval(60), periodSeconds: 86_400).groups
  #expect(groups.first { $0.runtime == .openCode }?.nativeSessionID == "ses_parent")
  #expect(groups.first { $0.runtime == .piCLI }?.model == "anthropic/claude-example")
  #expect(groups.allSatisfy { !$0.inWoven && $0.sessionID == nil })

  #expect(await scanner.scan().added == 0)

  let compressed = try Data(contentsOf: fixtures.appendingPathComponent(rollout + ".zst"))
  #expect(try Zstd.decompress(compressed) == Data(contentsOf: fixtures.appendingPathComponent(rollout)))
  try FileManager.default.removeItem(at: codex)
  try compressed.write(to: codex.appendingPathExtension("zst"))
  #expect(await scanner.scan().added == 0)

  let handle = try FileHandle(forWritingTo: claude)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((claudeLine("msg_two", at: "2026-01-05T11:05:00.000Z", input: 1, output: 1) + "\n").utf8))
  try handle.close()
  let appended = await scanner.scan()
  #expect(appended.read == 1 && appended.added == 1)
  #expect(try await totals(library) [.codex] == counted[.codex])
}

/// A turn Woven Matter ran is in the harness's own history too. It is
/// counted from there once, named as the Woven Matter session, while its
/// hour is open and after it moves to a synced record. Another machine sees
/// nothing of the open hour and the record once it is written.
@Test func aWovenSessionCountsOnceUnderItsName() async throws {
  let home = try temporary("usage-home")
  let now = Date()
  try write([claudeLine("msg_woven", at: now.formatted(.iso8601), input: 10, output: 5)],
            to: home.appendingPathComponent(".claude/projects/-tmp-example/\(claudeSession).jsonl"))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.setNativeSession("woven-session", runtime: .claudeCode, handle: claudeSession)
  let scanner = UsageScanner(library: library, home: home)
  #expect(await scanner.scan(now: now).records == 0)

  let other = try await Library.open(folder: try temporary("usage-library"), machineName: "b")
  func sync() async throws {
    while true {
      let page = try await library.pull(after: try await other.cursor(for: library.machineID), limit: 100)
      try await other.apply(page, from: library.machineID)
      if !page.more { break }
    }
  }
  func groups(_ library: Library) async throws -> [UsageGroup] {
    try await library.usage(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600), periodSeconds: 3600).groups
  }
  let open = try await groups(library)
  #expect(open.count == 1 && open[0].inWoven && open[0].sessionID == "woven-session" && open[0].amounts.requests == 1)
  try await sync()
  #expect(try await groups(other).isEmpty)

  #expect(try await library.flushUsage(now: now.addingTimeInterval(2 * 3600)) == 1)
  #expect(await scanner.scan(now: now.addingTimeInterval(2 * 3600)).added == 0)
  let records = try await library.rows("usage_records", where: "session_id", is: .text("woven-session"))
  #expect(records.count == 1 && records[0].values["woven"] == .integer(1))
  #expect(try await groups(library) == open)
  try await sync()
  #expect(try await groups(other) == open)
}

/// Anyone can write a history file, so malformed compressed input throws and
/// never traps: four streams for too few literals, a Huffman weight past 11,
/// a block larger than the format allows, every truncation and every one-byte
/// change of a real file.
@Test func malformedCompressedInputThrows() throws {
  let frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00]
  let fourStreams = frame + [0x1D, 0x00, 0x00, 0x16, 0x00, 0x00]
  let deepWeight = frame + [0x2D, 0x00, 0x00, 0x12, 0x80, 0x00, 0x80, 0xF0]
  let hugeBlock = frame + [0xFB, 0xFF, 0xFF, 0x41]
  for input in [fourStreams, deepWeight, hugeBlock] {
    #expect(throws: Zstd.Failure.self) { try Zstd.decompress(Data(input)) }
  }
  let real = try Data(contentsOf: fixtures.appendingPathComponent(rollout + ".zst"))
  for length in 1..<real.count {
    #expect(throws: Zstd.Failure.self) { try Zstd.decompress(real.prefix(length)) }
  }
  for index in real.indices {
    var changed = real
    changed[index] ^= 0x5A
    _ = try? Zstd.decompress(changed)
  }
}

/// A count or time too large for any real history is held to a ceiling.
@Test func aHugeNumberInAHistoryLineIsHeldToACeiling() async throws {
  var state = ReaderState()
  let line = #"{"type":"assistant","sessionId":"s","timestamp":1e300,"message":{"id":"m","model":"x","usage":{"input_tokens":1e30,"output_tokens":9223372036854775807,"cache_read_input_tokens":1}}}"#
  let entries = Array(line.utf8).withUnsafeBytes { HistoryReader.entries($0, kind: .claude(session: nil), state: &state) }
  #expect(entries.count == 1 && entries[0].input == 1_000_000_000_000 && entries[0].output == 1_000_000_000_000)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.saveUsage(entries + [UsageEntry(id: "other", runtime: .claudeCode, nativeSession: "s", model: "x", at: entries[0].at,
                                                    input: .max, output: .max)], source: UsageSource(id: "s"))
  _ = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: .max)
}
