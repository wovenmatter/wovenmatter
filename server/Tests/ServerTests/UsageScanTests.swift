import Foundation
import Synchronization
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

private func sync(_ from: Library, to other: Library) async throws {
  while true {
    let page = try await from.pull(after: try await other.cursor(for: from.machineID), limit: 100)
    try await other.apply(page, from: from.machineID)
    if !page.more { break }
  }
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
  #if os(macOS)
  // A history macOS flags hidden (a copy can carry the flag) is still read.
  var flagged = codex
  var hidden = URLResourceValues()
  hidden.isHidden = true
  try flagged.setResourceValues(hidden)
  #endif

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
/// counted from there once, named as the Woven Matter session, in a synced
/// row written as it is read, which another machine then shows the same.
@Test func aWovenSessionCountsOnceUnderItsName() async throws {
  let home = try temporary("usage-home")
  let now = Date()
  try write([claudeLine("msg_woven", at: now.formatted(.iso8601), input: 10, output: 5)],
            to: home.appendingPathComponent(".claude/projects/-tmp-example/\(claudeSession).jsonl"))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.setNativeSession("woven-session", runtime: .claudeCode, handle: claudeSession)
  let scanner = UsageScanner(library: library, home: home)
  #expect(await scanner.scan().records == 1)

  let other = try await Library.open(folder: try temporary("usage-library"), machineName: "b")
  func groups(_ library: Library) async throws -> [UsageGroup] {
    try await library.usage(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600), periodSeconds: 3600).groups
  }
  let read = try await groups(library)
  #expect(read.count == 1 && read[0].inWoven && read[0].sessionID == "woven-session" && read[0].amounts.requests == 1)
  #expect(await scanner.scan().added == 0)
  let records = try await library.rows("usage_hours", where: "session_id", is: .text("woven-session"))
  #expect(records.count == 1 && records[0].values["woven"] == .integer(1))
  try await sync(library, to: other)
  #expect(try await groups(other) == read)
}

/// A read is counted before it begins, so a history open when the process
/// ends is read again at the next start, and passed over only once it has
/// been open at two unclean ends in a row; then it is read again when it
/// changes. Another history is read all the while.
@Test func aHistoryOpenAtTwoUncleanEndsIsPassedOverUntilItChanges() async throws {
  let home = try temporary("usage-home")
  let project = home.appendingPathComponent(".claude/projects/-tmp-example")
  let fatal = project.appendingPathComponent(claudeSession + ".jsonl")
  try write([claudeLine("msg_fatal", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)], to: fatal)
  try write([claudeLine("msg_other", session: "22222222-2222-4333-8444-555555555555", at: "2026-01-05T11:00:02.000Z",
                        input: 2, output: 2)], to: project.appendingPathComponent("22222222-2222-4333-8444-555555555555.jsonl"))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let fatalID = UsageScanner.source("claude", "/-tmp-example/\(claudeSession).jsonl")

  // A process that ends while it reads the history: the read never returns,
  // and the next scanner starts on the same library. Returns the count the
  // library held as the read began.
  func readUntilTheProcessEnds() async -> Int64? {
    let (began, signal) = AsyncStream<Int64?>.makeStream()
    let scanner = UsageScanner(library: library, home: home) { source in
      guard source == fatalID else { return }
      signal.yield((try? await library.usageSources())?[source]?.interrupted)
      await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    Task { await scanner.scan() }
    for await interrupted in began { return interrupted }
    return nil
  }
  #expect(await readUntilTheProcessEnds() == 1)
  #expect(await readUntilTheProcessEnds() == 2)

  let opened = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home) { source in opened.withLock { $0.append(source) } }
  await scanner.scan()
  #expect(!opened.withLock { $0 }.contains(fatalID))
  #expect(try await totals(library)[.claudeCode]?.requests == 1)
  #expect(try await library.usageSources()[fatalID]?.interrupted == 0)
  #expect(await scanner.scan().read == 0)

  let handle = try FileHandle(forWritingTo: fatal)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((claudeLine("msg_later", at: "2026-01-05T11:05:00.000Z", input: 1, output: 1) + "\n").utf8))
  try handle.close()
  let changed = await scanner.scan()
  #expect(changed.read == 1 && changed.added == 2)
  #expect(try await library.usageSources()[fatalID]?.interrupted == 0)
}

/// A normal stop during a read lets it finish, so it leaves no count.
@Test func aStopDuringAReadLeavesNoCount() async throws {
  let home = try temporary("usage-home")
  try write([claudeLine("msg_one", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)],
            to: home.appendingPathComponent(".claude/projects/-tmp-example/\(claudeSession).jsonl"))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let (began, signal) = AsyncStream<Void>.makeStream()
  let scanner = UsageScanner(library: library, home: home) { _ in
    signal.yield()
    try? await Task.sleep(for: .seconds(30))
  }
  await scanner.start()
  for await _ in began { break }
  await scanner.stop()
  #expect(try await library.usageSources().values.map(\.interrupted) == [0])
  #expect(try await totals(library)[.claudeCode]?.requests == 1)
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

/// A count too large for any real history is held to a ceiling, and a
/// time no history can hold is no time.
@Test func aHugeNumberInAHistoryLineIsHeldToACeiling() async throws {
  var state = ReaderState()
  func entries(_ timestamp: String) -> [UsageEntry] {
    let line = #"{"type":"assistant","sessionId":"s","timestamp":\#(timestamp),"message":{"id":"m","model":"x","usage":{"input_tokens":1e30,"output_tokens":9223372036854775807,"cache_read_input_tokens":1}}}"#
    return Array(line.utf8).withUnsafeBytes { HistoryReader.entries($0, kind: .claude(session: nil), state: &state) }
  }
  #expect(entries("1e300").isEmpty && entries("-5").isEmpty && entries("4200000000").isEmpty)
  let entries = entries("1767610800")
  #expect(entries.count == 1 && entries[0].input == 1_000_000_000_000 && entries[0].output == 1_000_000_000_000)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  try await library.saveUsage(entries + [UsageEntry(id: "other", runtime: .claudeCode, nativeSession: "s", model: "x", at: entries[0].at,
                                                    input: .max, output: .max)], source: UsageSource(id: "s"))
  _ = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: .max)
}

private func append(_ lines: [String], to url: URL) throws {
  let handle = try FileHandle(forWritingTo: url)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
  try handle.close()
}

private func setModified(_ url: URL, _ date: Date) throws {
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func claudeFile(_ home: URL, _ session: String) -> URL {
  home.appendingPathComponent(".claude/projects/-tmp-example/\(session).jsonl")
}

private func session(_ index: Int) -> String { String(format: "%08d-2222-4333-8444-555555555555", index) }

/// A first line longer than any fixed probe still names the file, so a file
/// that grows is read on from where it stopped, not from its start.
@Test func aFileWithALongFirstLineIsReadOnFromItsPlace() async throws {
  let home = try temporary("usage-home")
  let file = claudeFile(home, claudeSession)
  let long = #"{"type":"user","sessionId":"\#(claudeSession)","message":{"content":"\#(String(repeating: "x", count: 10_000))"}}"#
  try write([long, claudeLine("msg_one", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)], to: file)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  #expect(await scanner.scan().found == 1)
  try append([claudeLine("msg_two", at: "2026-01-05T11:00:02.000Z", input: 1, output: 1)], to: file)
  let next = await scanner.scan()
  #expect(next.read == 1 && next.found == 1 && next.added == 1)
}

/// A history larger than one read's worth is read to its end in one pass,
/// and a line longer than that is passed over on its own.
@Test func aFileLargerThanAChunkIsReadToItsEndInOnePass() async throws {
  let home = try temporary("usage-home")
  var lines = (0..<40).map { claudeLine("msg_\($0)", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1) }
  lines.insert(#"{"type":"user","message":"\#(String(repeating: "y", count: 2_000))"}"#, at: 20)
  try write(lines, to: claudeFile(home, claudeSession))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home, chunk: 1_000)
  let pass = await scanner.scan()
  #expect(pass.added == 40 && pass.left == 0)
  #expect(try await totals(library)[.claudeCode]?.requests == 40)
  #expect(await scanner.scan().read == 0)
}

/// Builds a Zstandard stream of raw blocks with a 1 KiB window, the format
/// at its simplest, as many frames as the data needs.
private func rawFrames(_ data: Data) -> Data {
  var output = Data()
  var rest = data[...]
  repeat {
    output += Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00])
    var blocks = 0
    repeat {
      let piece = rest.prefix(1024)
      rest = rest.dropFirst(piece.count)
      blocks += 1
      let last = rest.isEmpty || blocks == 64
      let header = piece.count << 3 | (last ? 1 : 0)
      output += Data([UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16 & 0xFF)]) + piece
      if last { break }
    } while true
  } while !rest.isEmpty
  return output
}

/// A compressed rollout is decoded as a stream in bounded memory, so one far
/// larger than the window and than a read's worth is read whole; a frame
/// whose window is larger than allowed is refused; and a decoded file read
/// again goes on from its place.
@Test func aCompressedRolloutOfAnySizeIsReadWhole() async throws {
  let home = try temporary("usage-home")
  let thread = "0000bbbb-0000-7000-8000-000000000002"
  var lines = [#"{"timestamp":"2026-01-05T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(thread)"}}"#,
               #"{"timestamp":"2026-01-05T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t","model":"gpt-example"}}"#]
  for index in 0..<2_000 {
    lines.append(#"{"timestamp":"2026-01-05T10:01:00.000Z","type":"token_usage_record","payload":{"thread_id":"\#(thread)","response_id":"resp_\#(index)","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2,"total_tokens":12}}}"#)
  }
  let plain = Data(lines.map { $0 + "\n" }.joined().utf8)
  let compressed = rawFrames(plain)
  #expect(try Zstd.decompress(compressed) == plain)
  var small = Zstd.Decoder(compressed, maximumWindow: 512)
  #expect(throws: Zstd.Failure.self) { _ = try small.next() }

  let url = home.appendingPathComponent(".codex/archived_sessions/rollout-2026-01-05T10-00-00-\(thread).jsonl.zst")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try compressed.write(to: url)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home, chunk: 50_000)
  #expect(await scanner.scan().added == 2_000)
  #expect(try await totals(library)[.codex] == UsageAmounts(input: 12_000, output: 4_000, cacheRead: 8_000, requests: 2_000))
  try setModified(url, Date())
  let again = await scanner.scan()
  #expect(again.read == 1 && again.found == 0)
}

/// A file rewritten before the place it was read to is read again from its
/// start; what was counted already counts once.
@Test func aRewrittenPrefixIsReadFromTheStart() async throws {
  let home = try temporary("usage-home")
  let file = claudeFile(home, claudeSession)
  let first = claudeLine("msg_one", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)
  try write([first, claudeLine("msg_two", at: "2026-01-05T11:00:02.000Z", input: 1, output: 1)], to: file)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  #expect(await scanner.scan().added == 2)
  try write([first, claudeLine("msg_new", at: "2026-01-05T11:00:03.000Z", input: 1, output: 1),
             claudeLine("msg_two", at: "2026-01-05T11:00:02.000Z", input: 1, output: 1),
             claudeLine("msg_last", at: "2026-01-05T11:00:04.000Z", input: 1, output: 1)], to: file)
  let next = await scanner.scan()
  #expect(next.found == 4 && next.added == 2)
  #expect(try await totals(library)[.claudeCode]?.requests == 4)
}

/// Reading every history again from the start, as after its places were
/// lost, finds everything again and changes nothing: the same rows, the
/// same sums, no row written again.
@Test func readingEverythingAgainChangesNothing() async throws {
  let home = try temporary("usage-home")
  let codex = home.appendingPathComponent(".codex/sessions/2026/01/05/" + rollout)
  try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixtures.appendingPathComponent(rollout), to: codex)
  for index in 0..<3 {
    try write((0..<5).map { claudeLine("msg_\(index)_\($0)", session: session(index), at: "2026-01-0\(index + 1)T11:00:0\($0).000Z",
                                       input: 1, output: $0) }, to: claudeFile(home, session(index)))
  }
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  await scanner.scan()
  func rows() async throws -> [SyncRow] { try await library.rows("usage_hours", where: "machine_id", is: .text(library.machineID)) }
  let before = try await rows(), sums = try await totals(library)
  for id in try await library.usageSources().keys { try await library.saveUsage([], source: UsageSource(id: id)) }
  let again = await scanner.scan()
  #expect(again.read == 4 && again.added == 0 && again.records == 0)
  #expect(try await rows() == before)
  #expect(try await totals(library) == sums)
}

/// A response seen again with fuller counts (a streamed message's final
/// line) takes them, in whichever order its lines are read; seen again with
/// fewer, it keeps what it had.
@Test func theFullestObservationOfAResponseWins() async throws {
  let home = try temporary("usage-home")
  let file = claudeFile(home, claudeSession)
  try write([claudeLine("msg_one", at: "2026-01-05T11:00:01.000Z", input: 3, output: 1)], to: file)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  await scanner.scan()
  try append([claudeLine("msg_one", at: "2026-01-05T11:00:02.000Z", input: 3, output: 40),
              claudeLine("msg_one", at: "2026-01-05T11:00:03.000Z", input: 3, output: 2)], to: file)
  let pass = await scanner.scan()
  #expect(pass.added == 0 && pass.records == 1)
  #expect(try await totals(library)[.claudeCode] == UsageAmounts(input: 3, output: 40, requests: 1))
}

/// A pass reads the histories that grew first, then the rest newest first,
/// reporting each age reached; with no time left it ends after one history
/// and the next pass goes on.
@Test func historiesAreReadNewestFirstAcrossPasses() async throws {
  let home = try temporary("usage-home")
  let now = Date()
  let ages: [Double] = [200, 60, 20, 3, 0.1].map { $0 * 86_400 }
  for (index, age) in ages.enumerated() {
    let file = claudeFile(home, session(index))
    try write([claudeLine("msg_\(index)", session: session(index), at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)], to: file)
    try setModified(file, now.addingTimeInterval(-age))
  }
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let order = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home, slice: .zero) { source in order.withLock { $0.append(source) } }
  var passes = 0
  while true {
    passes += 1
    if await scanner.scan().left == 0 { break }
  }
  let expected = (0..<5).reversed().map { UsageScanner.source("claude", "/-tmp-example/\(session($0)).jsonl") }
  #expect(passes == 5 && order.withLock { $0 } == expected)

  // A history that grew is read before one never read, however old.
  order.withLock { $0.removeAll() }
  let grown = claudeFile(home, session(0))
  try append([claudeLine("msg_more", session: session(0), at: "2026-01-05T11:00:02.000Z", input: 1, output: 1)], to: grown)
  try setModified(grown, now.addingTimeInterval(-300 * 86_400))
  let fresh = claudeFile(home, session(9))
  try write([claudeLine("msg_9", session: session(9), at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)], to: fresh)
  #expect(await scanner.scan().left == 0)
  #expect(order.withLock { $0 } == [0, 9].map { UsageScanner.source("claude", "/-tmp-example/\(session($0)).jsonl") })
}

/// A clock that moves on a second each time it is read.
private func tickingClock() -> @Sendable () -> Duration {
  let ticks = Mutex(0)
  return { ticks.withLock { $0 += 1; return .seconds($0) } }
}

private func manyLines(_ prefix: String, session: String = claudeSession, count: Int) -> [String] {
  (0..<count).map { claudeLine("\(prefix)_\($0)", session: session, at: "2026-01-05T11:00:01.000Z", input: 1, output: 1) }
}

/// A history that keeps growing cannot hold up those not read yet: they
/// have half of every pass.
@Test func historiesThatGrowLeaveTimeForTheRest() async throws {
  let home = try temporary("usage-home")
  let busy = claudeFile(home, session(1))
  try write(manyLines("first", session: session(1), count: 1), to: busy)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let order = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home, chunk: 1_000, slice: .seconds(10),
                             willRead: { source in order.withLock { $0.append(source) } }, clock: tickingClock())
  #expect(await scanner.scan().left == 0)
  try append(manyLines("more", session: session(1), count: 200), to: busy)
  for index in 2...3 { try write(manyLines("waiting", session: session(index), count: 1), to: claudeFile(home, session(index))) }
  order.withLock { $0.removeAll() }
  let pass = await scanner.scan()
  #expect(pass.left == 1)
  #expect(Set(order.withLock { $0 }).isSuperset(of: (2...3).map { UsageScanner.source("claude", "/-tmp-example/\(session($0)).jsonl") }))
}

/// A history read only part of the way is still waiting to be read, not one
/// that grew: one newer than it is read first.
@Test func aPartlyReadHistoryWaitsItsTurn() async throws {
  let home = try temporary("usage-home")
  let old = claudeFile(home, session(1))
  try write(manyLines("old", session: session(1), count: 200), to: old)
  try setModified(old, Date().addingTimeInterval(-86_400))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let order = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home, chunk: 1_000, slice: .seconds(4),
                             willRead: { source in order.withLock { $0.append(source) } }, clock: tickingClock())
  #expect(await scanner.scan().left == 1)
  try write(manyLines("new", session: session(2), count: 1), to: claudeFile(home, session(2)))
  order.withLock { $0.removeAll() }
  await scanner.scan()
  #expect(order.withLock { $0 }.first == UsageScanner.source("claude", "/-tmp-example/\(session(2)).jsonl"))
}

/// Each age is reported once as the reading reaches it, also when every
/// history is recent, and not again while nothing old is waiting.
@Test func eachStageIsReportedOnce() async throws {
  let home = try temporary("usage-home")
  try write(manyLines("one", count: 1), to: claudeFile(home, claudeSession))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let lines = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home, log: { line in lines.withLock { $0.append(line) } })
  await scanner.scan()
  try write(manyLines("two", session: session(2), count: 1), to: claudeFile(home, session(2)))
  await scanner.scan()
  let stages = lines.withLock { $0 }.filter { $0.hasPrefix("usage history read") }
  #expect(stages == ["24 hours", "7 days", "30 days", "90 days"].map { "usage history read back \($0) (1 histories)" }
            + ["usage history read in full (1 histories)"])
}

/// A save that fails leaves the place where it was, so nothing read before
/// the failure is skipped when the history is read again.
@Test func aFailedSaveKeepsThePlace() async throws {
  let home = try temporary("usage-home")
  let file = claudeFile(home, claudeSession)
  try write(manyLines("msg", count: 3), to: file)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  await scanner.failNextSaves(1)
  #expect(await scanner.scan().added == 0)
  #expect(try await library.usageSources().values.map(\.offset) == [0])
  try append(manyLines("later", count: 1), to: file)
  #expect(await scanner.scan().added == 4)
  #expect(try await totals(library)[.claudeCode]?.requests == 4)
}

/// A line longer than a read's worth is passed over with every one of its
/// bytes, so the place after it is where the next line starts.
@Test func aLineLongerThanAChunkIsPassedOverWhole() async throws {
  let home = try temporary("usage-home")
  let file = claudeFile(home, claudeSession)
  let long = #"{"type":"user","message":"\#(String(repeating: "z", count: 5_000))"}"#
  try write(manyLines("before", count: 2) + [long] + manyLines("after", count: 2), to: file)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home, chunk: 1_000)
  #expect(await scanner.scan().added == 4)
  let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
  #expect(try await library.usageSources().values.map(\.offset) == [size?.int64Value ?? -1])
  try append(manyLines("last", count: 1), to: file)
  let next = await scanner.scan()
  #expect(next.found == 1 && next.added == 1)
}

/// A compressed rollout that cannot be decoded part of the way keeps what
/// was read before the bad block.
@Test func aCompressedRolloutFailingPartWayKeepsWhatCameBefore() async throws {
  let home = try temporary("usage-home")
  let thread = "0000dddd-0000-7000-8000-000000000008"
  var lines = [#"{"timestamp":"2026-01-05T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(thread)"}}"#]
  for index in 0..<400 {
    lines.append(#"{"timestamp":"2026-01-05T10:01:00.000Z","type":"token_usage_record","payload":{"thread_id":"\#(thread)","response_id":"resp_\#(index)","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}"#)
  }
  let plain = Data(lines.map { $0 + "\n" }.joined().utf8)
  var compressed = rawFrames(plain)
  // The 41st block of the first frame is given the reserved block type.
  let bad = 6 + 40 * (3 + 1024)
  compressed[bad] |= 0x06
  let before = plain.prefix(40 * 1024).split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
  let url = home.appendingPathComponent(".codex/sessions/2026/01/05/rollout-2026-01-05T10-00-00-\(thread).jsonl.zst")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try compressed.write(to: url)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home)
  await scanner.scan()
  #expect(try await totals(library)[.codex]?.requests == before.count - 1)
  #expect(try await library.usageSources().values.allSatisfy { $0.passedOver > 0 })
}

/// The homes the server's environment names and the Claude app's own
/// Claude Code transcripts are read too, each file once, under keys of their own.
@Test func environmentHomesAndTheClaudeAppAreRead() async throws {
  let home = try temporary("usage-home")
  let elsewhere = try temporary("usage-elsewhere")
  try write([claudeLine("msg_home", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)], to: claudeFile(home, claudeSession))
  // The same relative path under another root is another history.
  try write([claudeLine("msg_config", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)],
            to: elsewhere.appendingPathComponent("claude/projects/-tmp-example/\(claudeSession).jsonl"))
  try write([claudeLine("msg_xdg", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)],
            to: home.appendingPathComponent(".config/claude/projects/-tmp-example/\(claudeSession).jsonl"))
  let codex = elsewhere.appendingPathComponent("codex/sessions/2026/01/05/" + rollout)
  try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixtures.appendingPathComponent(rollout), to: codex)
  #if os(macOS)
  try write([claudeLine("msg_desktop", at: "2026-01-05T11:00:01.000Z", input: 1, output: 1)],
            to: home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions/a/b/.claude/projects/-x/\(claudeSession).jsonl"))
  #endif
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let scanner = UsageScanner(library: library, home: home, environment: [
    "CLAUDE_CONFIG_DIR": elsewhere.appendingPathComponent("claude").path, "CODEX_HOME": elsewhere.appendingPathComponent("codex").path,
  ])
  let pass = await scanner.scan()
  #if os(macOS)
  #expect(pass.read == 5 && pass.added == 4 + 30)
  #else
  #expect(pass.read == 4 && pass.added == 3 + 30)
  #endif
  #expect(try await totals(library)[.codex]?.requests == 30)
}

/// Epoch milliseconds and microseconds are told from seconds by their size,
/// and Grok Build's turn counts the model calls it took.
@Test func timesInAnyUnitLandOnTheirDayAndGrokCountsItsCalls() throws {
  let day = Date(timeIntervalSince1970: 1_767_610_800)
  for value: Any in [1_767_610_800, 1_767_610_800_000, 1_767_610_800_000_000, 1_767_610_800_000_000_000, "2026-01-05T11:00:00Z"] {
    #expect(HistoryReader.date(value) == day)
  }
  #expect(HistoryReader.date(1e21) == nil && HistoryReader.date(12) == nil)
  let session = "0193aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee"
  let line = #"{"timestamp":1767610801,"timestamp_us":1767610801000000,"method":"_x.ai/session/update","params":{"sessionId":"\#(session)","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":100,"outputTokens":7,"modelCalls":3,"modelUsage":{"grok-a":{"inputTokens":60,"outputTokens":5,"modelCalls":2},"grok-b":{"inputTokens":40,"outputTokens":2,"modelCalls":1}}}},"_meta":{"eventId":"\#(session)-5"}}}"#
  var state = ReaderState()
  let entries = Array(line.utf8).withUnsafeBytes {
    HistoryReader.entries($0, kind: .grok(session: session, summary: URL(fileURLWithPath: "/nonexistent")), state: &state)
  }
  #expect(entries.map(\.requests).sorted() == [1, 2] && entries.allSatisfy { $0.at == day.addingTimeInterval(1) })

  // A turn's own count goes to its one model; with several and no counts of
  // their own, each counts one call.
  func requests(_ usage: String) -> [Int64] {
    let line = #"{"timestamp":1767610801,"method":"_x.ai/session/update","params":{"sessionId":"\#(session)","update":{"sessionUpdate":"turn_completed","prompt_id":"p2","usage":\#(usage)},"_meta":{"eventId":"\#(session)-6"}}}"#
    var state = ReaderState()
    return Array(line.utf8).withUnsafeBytes {
      HistoryReader.entries($0, kind: .grok(session: session, summary: URL(fileURLWithPath: "/nonexistent")), state: &state)
    }.map(\.requests).sorted()
  }
  #expect(requests(#"{"inputTokens":10,"outputTokens":1,"modelCalls":3,"modelUsage":{"grok-a":{"inputTokens":6,"outputTokens":1},"grok-b":{"inputTokens":4,"outputTokens":1}}}"#) == [1, 1])
  #expect(requests(#"{"inputTokens":10,"outputTokens":1,"modelCalls":3,"modelUsage":{"grok-a":{"inputTokens":10,"outputTokens":1}}}"#) == [3])
  #expect(requests(#"{"inputTokens":10,"outputTokens":1,"modelCalls":3}"#) == [3])
}

private func codexMeta(_ id: String, at: String = "2026-03-01T10:00:00.000Z") -> String {
  #"{"timestamp":"\#(at)","type":"session_meta","payload":{"id":"\#(id)","originator":"codex_cli_rs"}}"#
}

private func codexUsage(_ input: Int, _ cached: Int, _ output: Int) -> String {
  #"{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)}"#
}

/// A `token_count` event; `total` is the thread's running total so far.
private func codexCount(at: String, last: (Int, Int, Int), total: (Int, Int, Int)) -> String {
  #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(codexUsage(total.0, total.1, total.2)),"last_token_usage":\#(codexUsage(last.0, last.1, last.2))}}}"#
}

private func codexRecord(at: String, thread: String, response: String, _ usage: (Int, Int, Int)) -> String {
  #"{"timestamp":"\#(at)","type":"token_usage_record","payload":{"thread_id":"\#(thread)","response_id":"\#(response)","usage":\#(codexUsage(usage.0, usage.1, usage.2))}}"#
}

/// Older Codex releases record each response only as a `token_count` event.
/// One counts when the running total moves; a repeated total, an event with
/// no usage, one restating a `token_usage_record` (also one copied from
/// another thread) and a resumed thread's first total, which carries what
/// came before, count nothing. A forked thread's copies of its parent's
/// events count once, at the parent's time and in its session, and a copy
/// of an event restating a record counts nothing, in whichever order the
/// files are read; the reader's state carries across chunks.
@Test func olderCodexResponsesAreCountedFromTheirRunningTotals() async throws {
  let home = try temporary("usage-home")
  let parent = "0000cccc-0000-7000-8000-000000000003", fork = "0000cccc-0000-7000-8000-000000000004"
  let other = "0000cccc-0000-7000-8000-000000000005"
  let folder = home.appendingPathComponent(".codex/sessions/2026/03/01")
  let parentEvents = [
    codexCount(at: "2026-03-01T10:01:00.000Z", last: (100, 0, 10), total: (100, 0, 10)),
    codexCount(at: "2026-03-01T10:01:00.500Z", last: (100, 0, 10), total: (100, 0, 10)),
    codexCount(at: "2026-03-01T10:02:00.000Z", last: (200, 100, 20), total: (300, 100, 30)),
  ]
  try write([codexMeta(parent), #"{"timestamp":"2026-03-01T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-old"}}"#]
            + parentEvents + [
    #"{"timestamp":"2026-03-01T10:02:30.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
    codexRecord(at: "2026-03-01T10:03:00.000Z", thread: parent, response: "resp_new", (400, 300, 40)),
    codexCount(at: "2026-03-01T10:03:05.000Z", last: (400, 300, 40), total: (700, 400, 70)),
    codexRecord(at: "2026-03-01T10:04:00.000Z", thread: other, response: "resp_other", (50, 0, 5)),
    codexCount(at: "2026-03-01T10:04:00.000Z", last: (50, 0, 5), total: (750, 400, 75)),
    codexCount(at: "2026-03-01T10:05:00.000Z", last: (1000, 600, 100), total: (1750, 1000, 175)),
  ], to: folder.appendingPathComponent("rollout-2026-03-01T10-00-00-\(parent).jsonl"))
  // The fork copies its parent's events at the time it was made, then works on.
  let copied = parentEvents.map { $0.replacingOccurrences(of: #"2026-03-01T10:0[12]:00\.[05]00Z"#, with: "2026-03-01T12:00:00.000Z",
                                                          options: .regularExpression) }
  try write([codexMeta(fork, at: "2026-03-01T12:00:00.000Z")] + copied + [
    codexCount(at: "2026-03-01T12:01:00.000Z", last: (3000, 0, 300), total: (3300, 100, 330)),
  ], to: folder.appendingPathComponent("rollout-2026-03-01T12-00-00-\(fork).jsonl"))
  // A resumed thread's first total holds what its earlier part used.
  let resumed = "0000cccc-0000-7000-8000-000000000006"
  try write([codexMeta(resumed),
             codexCount(at: "2026-03-01T13:00:00.000Z", last: (80, 0, 8), total: (5000, 0, 500)),
             codexCount(at: "2026-03-01T13:01:00.000Z", last: (90, 0, 9), total: (5090, 0, 509))],
            to: folder.appendingPathComponent("rollout-2026-03-01T13-00-00-\(resumed).jsonl"))

  // A thread that starts from another's state copies the event restating
  // that thread's last record, stamped with its own time.
  let review = "0000cccc-0000-7000-8000-000000000007"
  try write([codexMeta(review, at: "2026-03-01T14:00:00.000Z"),
             codexCount(at: "2026-03-01T14:00:00.000Z", last: (400, 300, 40), total: (700, 400, 70)),
             codexCount(at: "2026-03-01T14:00:05.000Z", last: (60, 0, 6), total: (760, 400, 76))],
            to: folder.appendingPathComponent("rollout-2026-03-01T14-00-00-\(review).jsonl"))

  // Each order of reading gives the same ledger.
  var results: [[RuntimeKind: UsageAmounts]] = []
  for newestFirst in [true, false] {
    let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
    try setModified(folder.appendingPathComponent("rollout-2026-03-01T12-00-00-\(fork).jsonl"),
                    Date().addingTimeInterval(newestFirst ? 0 : -3600))
    try setModified(folder.appendingPathComponent("rollout-2026-03-01T14-00-00-\(review).jsonl"),
                    Date().addingTimeInterval(newestFirst ? 10 : -7200))
    let scanner = UsageScanner(library: library, home: home, chunk: 1_000)
    await scanner.scan()
    results.append(try await totals(library))
    let groups = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 3600).groups
    let parentHour = groups.filter { $0.nativeSessionID == parent }
    #expect(parentHour.reduce(0) { $0 + $1.amounts.requests } == 4 && parentHour.allSatisfy { $0.model == "gpt-old" })
    #expect(groups.filter { $0.nativeSessionID == fork }.map(\.amounts.requests) == [1])
    #expect(groups.filter { $0.nativeSessionID == resumed }.map(\.amounts.requests) == [1])
    #expect(groups.filter { $0.nativeSessionID == review }.map(\.amounts.requests) == [1])
  }
  // Parent: two responses from running totals, the record and the last event; fork, resumed and review: one each.
  #expect(results[0] == results[1])
  #expect(results[0][.codex] == UsageAmounts(input: 100 + 100 + 100 + 400 + 3000 + 90 + 60,
                                             output: 10 + 20 + 40 + 100 + 300 + 9 + 6, cacheRead: 100 + 300 + 600, requests: 7))
}

private func codexTurn(_ turn: String, at: String) -> String {
  #"{"timestamp":"\#(at)","type":"turn_context","payload":{"turn_id":"\#(turn)","model":"gpt-old"}}"#
}

/// Two threads whose first responses used exactly the same tokens are two
/// responses; a fork's copy of one, with its turn or without, is the same
/// response. A record left unrestated in one turn is not taken for a
/// response of the next.
@Test func olderCodexResponsesAreToldApartByTheirTurn() async throws {
  let home = try temporary("usage-home")
  let folder = home.appendingPathComponent(".codex/sessions/2026/03/02")
  let first = "0000eeee-0000-7000-8000-000000000001", second = "0000eeee-0000-7000-8000-000000000002"
  let fork = "0000eeee-0000-7000-8000-000000000003"
  let response = codexCount(at: "2026-03-02T10:01:00.000Z", last: (500, 0, 50), total: (500, 0, 50))
  try write([codexMeta(first, at: "2026-03-02T10:00:00.000Z"), codexTurn("turn-first", at: "2026-03-02T10:00:01.000Z"), response],
            to: folder.appendingPathComponent("rollout-2026-03-02T10-00-00-\(first).jsonl"))
  try write([codexMeta(second, at: "2026-03-02T11:00:00.000Z"), codexTurn("turn-second", at: "2026-03-02T11:00:01.000Z"),
             response.replacingOccurrences(of: "10:01:00", with: "11:01:00")],
            to: folder.appendingPathComponent("rollout-2026-03-02T11-00-00-\(second).jsonl"))
  // The fork copies the first thread's turn as it was, stamped with its own time.
  try write([codexMeta(fork, at: "2026-03-02T12:00:00.000Z"), codexTurn("turn-first", at: "2026-03-02T12:00:00.000Z"),
             response.replacingOccurrences(of: "10:01:00", with: "12:00:00")],
            to: folder.appendingPathComponent("rollout-2026-03-02T12-00-00-\(fork).jsonl"))
  // Another copies it without its turn.
  let bare = "0000eeee-0000-7000-8000-000000000005"
  try write([codexMeta(bare, at: "2026-03-02T12:30:00.000Z"), response.replacingOccurrences(of: "10:01:00", with: "12:30:00")],
            to: folder.appendingPathComponent("rollout-2026-03-02T12-30-00-\(bare).jsonl"))
  // A record no event restates, then the next turn's response of the same size.
  let leftover = "0000eeee-0000-7000-8000-000000000004"
  try write([codexMeta(leftover, at: "2026-03-02T13:00:00.000Z"), codexTurn("turn-a", at: "2026-03-02T13:00:01.000Z"),
             codexRecord(at: "2026-03-02T13:01:00.000Z", thread: leftover, response: "resp_a", (70, 0, 7)),
             codexTurn("turn-b", at: "2026-03-02T13:02:00.000Z"),
             codexCount(at: "2026-03-02T13:03:00.000Z", last: (70, 0, 7), total: (70, 0, 7))],
            to: folder.appendingPathComponent("rollout-2026-03-02T13-00-00-\(leftover).jsonl"))
  // The same, where the next turn starts with no turn_context of its own.
  let started = "0000eeee-0000-7000-8000-000000000006"
  try write([codexMeta(started, at: "2026-03-02T14:00:00.000Z"), codexTurn("turn-c", at: "2026-03-02T14:00:01.000Z"),
             codexRecord(at: "2026-03-02T14:01:00.000Z", thread: started, response: "resp_c", (80, 0, 8)),
             #"{"timestamp":"2026-03-02T14:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"rollout-2"}}"#,
             codexCount(at: "2026-03-02T14:03:00.000Z", last: (80, 0, 8), total: (80, 0, 8))],
            to: folder.appendingPathComponent("rollout-2026-03-02T14-00-00-\(started).jsonl"))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  await UsageScanner(library: library, home: home).scan()
  let groups = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 3600).groups
  func requests(_ thread: String) -> Int { groups.filter { $0.nativeSessionID == thread }.reduce(0) { $0 + $1.amounts.requests } }
  #expect(requests(first) == 1 && requests(second) == 1 && requests(fork) == 0 && requests(bare) == 0 && requests(leftover) == 2)
  #expect(requests(started) == 2)
}

/// OpenCode's hour before its place is read again with a place of its own,
/// so a slice that ends inside it goes on from there and the read finishes.
@Test func openCodesHourBeforeItsPlaceIsReadOnAcrossPasses() async throws {
  let home = try temporary("usage-home")
  let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try DatabaseFile.create(at: url)
  let database = try DatabaseFile(url: url, isCopy: false)
  _ = try database.execute("""
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER,
      time_updated INTEGER, data TEXT);
    """)
  func insert(_ range: Range<Int>) throws {
    let rows = range.map { index in
      let at = 1_767_614_400_000 + Int64(index) * 1000
      return "('msg_\(String(format: "%04d", index))', 'ses', 'assistant', \(index), \(at), \(at), "
        + #"'{"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"cost":0,"model":{"id":"m","providerID":"p"},"time":{"completed":\#(at)}}')"#
    }
    _ = try database.execute("INSERT INTO session_message VALUES " + rows.joined(separator: ", "))
  }
  try insert(0..<700)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  #expect(await UsageScanner(library: library, home: home).scan().added == 700)
  try insert(700..<701)
  let scanner = UsageScanner(library: library, home: home, slice: .seconds(1), clock: tickingClock())
  var passes = 0
  while passes < 10 {
    passes += 1
    if await scanner.scan().left == 0 { break }
  }
  #expect(passes < 10)
  #expect(try await totals(library)[.openCode]?.requests == 701)
}

/// When one history uses a pass's share without reaching its end, the next
/// pass begins with the one after it.
@Test func aHistoryThatTakesItsShareLetsTheNextOneGoFirst() async throws {
  let home = try temporary("usage-home")
  let slow = claudeFile(home, session(1)), older = claudeFile(home, session(2))
  try write(manyLines("slow", session: session(1), count: 400), to: slow)
  try write(manyLines("older", session: session(2), count: 1), to: older)
  try setModified(older, Date().addingTimeInterval(-3600))
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let order = Mutex<[String]>([])
  let scanner = UsageScanner(library: library, home: home, chunk: 1_000, slice: .seconds(2),
                             willRead: { source in order.withLock { $0.append(source) } }, clock: tickingClock())
  await scanner.scan()
  #expect(order.withLock { $0 } == [UsageScanner.source("claude", "/-tmp-example/\(session(1)).jsonl")])
  order.withLock { $0.removeAll() }
  await scanner.scan()
  #expect(order.withLock { $0 }.first == UsageScanner.source("claude", "/-tmp-example/\(session(2)).jsonl"))
}

/// A stop reaches the scanner while it decodes a large compressed rollout,
/// which then ends where it was, counting nothing as interrupted.
@Test func aStopReachesALongCompressedRead() async throws {
  let home = try temporary("usage-home")
  let thread = "0000ffff-0000-7000-8000-000000000009"
  var lines = [#"{"timestamp":"2026-01-05T10:00:00.000Z","type":"session_meta","payload":{"id":"\#(thread)"}}"#]
  for index in 0..<100_000 {
    lines.append(#"{"timestamp":"2026-01-05T10:01:00.000Z","type":"token_usage_record","payload":{"thread_id":"\#(thread)","response_id":"resp_\#(index)","usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}"#)
  }
  let plain = Data(lines.map { $0 + "\n" }.joined().utf8)
  let url = home.appendingPathComponent(".codex/sessions/2026/01/05/rollout-2026-01-05T10-00-00-\(thread).jsonl.zst")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try rawFrames(plain).write(to: url)
  let library = try await Library.open(folder: try temporary("usage-library"), machineName: "a")
  let (began, signal) = AsyncStream<Void>.makeStream()
  let scanner = UsageScanner(library: library, home: home, chunk: 1 << 30) { _ in signal.yield() }
  await scanner.start()
  for await _ in began { break }
  try await Task.sleep(for: .milliseconds(200))
  await scanner.stop()
  let sources = try await library.usageSources().values
  #expect(sources.count == 1 && sources.allSatisfy { $0.interrupted == 0 && $0.offset < Int64(plain.count) })
}

/// A subscriber that has not taken a library event yet gets, with the one
/// that replaces it, the tables of both.
@Test func aReplacedLibraryEventKeepsItsTables() async {
  let (events, continuation) = AsyncStream<LibraryEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
  deliver(LibraryEvent(changed: 1, tables: ["usage_hours"]), to: continuation)
  deliver(LibraryEvent(changed: 2, tables: ["settings"]), to: continuation)
  continuation.finish()
  var received: [LibraryEvent] = []
  for await event in events { received.append(event) }
  #expect(received == [LibraryEvent(changed: 2, tables: ["settings", "usage_hours"])])
}
