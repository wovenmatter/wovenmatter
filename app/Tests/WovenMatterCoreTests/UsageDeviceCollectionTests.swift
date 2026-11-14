import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Usage from linked devices")
struct UsageDeviceCollectionTests {
  private static let now = Date(timeIntervalSince1970: 1_793_894_400)
  private static let mac = UsageDeviceIdentity(id: "mac-2", name: "Studio", kind: .mac)
  private static let host = UsageDeviceIdentity(id: "host-1", name: "Build host", kind: .linux)

  private func withService(_ body: (LocalUsageService) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-devices-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(Self.service(home: directory, database: directory.appending(path: "usage.sqlite")))
  }

  /// Each service gets its own import worker, so tests running side by side never fill one.
  private static func service(home: URL, database: URL) -> LocalUsageService {
    LocalUsageService(
      homeDirectory: home,
      fileManager: .default,
      credentialStore: UsageNoCredentials(recordsAccess: true),
      usageDatabaseURL: database,
      sharedConnectionRevision: { 0 },
      importPreparationWorker: DatabaseWorker(label: "usage.import.devices.fixture", capacity: 8)
    )
  }

  private func analytics(_ service: LocalUsageService) async throws -> [UsageSample] {
    try await service.analyticsSnapshot(range: .allTime, refreshReason: .rangeChanged, now: Self.now).samples
  }

  private func record(
    _ id: String,
    tokens: Int64 = 100,
    daysAgo: Double = 1,
    device: String? = nil,
    harness: String = "Codex",
    workspace: String? = nil
  ) -> UsageDeviceRecord {
    var value = UsageDeviceRecord(sample: UsageSample(
      id: id,
      provider: .codex,
      timestamp: Self.now.addingTimeInterval(-daysAgo * 86_400),
      sessionID: "session-\(id)",
      accountLabel: "Account",
      model: "gpt-5.5",
      harness: harness,
      application: "Codex",
      workspace: workspace,
      tokens: UsageTokenCounts(inputTokens: tokens),
      sourceID: "codex:file:/secret/path/\(id)",
      sourceEventID: id
    ))
    value.device = device
    return value
  }

  private func endpoint(
    _ identity: UsageDeviceIdentity = mac,
    keepsLastingHistory: Bool = false,
    excludedRelays: Set<String> = [],
    fetch: @escaping @Sendable (UsageDeviceExportRequest) async throws -> UsageDeviceExportPage
  ) -> UsageDeviceEndpoint {
    UsageDeviceEndpoint(
      identity: identity,
      keepsLastingHistory: keepsLastingHistory,
      excludedRelays: excludedRelays,
      fetch: fetch
    )
  }

  @Test("a device's usage arrives across pages and stays attributed to it")
  func storesPages() async throws {
    try await withService { service in
      let records = (0..<5).map { record("r\($0)") }
      let summary = await service.collectDeviceUsage(from: endpoint { request in
        let page = records.dropFirst(request.offset).prefix(2)
        return .init(state: .ready, generatedAt: 0, records: Array(page),
          hasMore: request.offset + page.count < records.count, nextOffset: request.offset + page.count)
      }, now: Self.now)
      #expect(summary.state == .synced)
      let samples = try await analytics(service)
      #expect(samples.count == 5)
      #expect(samples.allSatisfy { $0.usageDeviceID == "mac-2" })
      #expect(await service.storedDeviceSummaries().map(\.identity) == [Self.mac])
    }
  }

  @Test("a failed read keeps what the device reported before")
  func failedReadKeepsHistory() async throws {
    try await withService { service in
      _ = await service.collectDeviceUsage(from: endpoint { _ in
        .paged([self.record("kept")], request: .init(since: 0, offset: 0))
      }, now: Self.now)
      let failed = await service.collectDeviceUsage(from: endpoint { request in
        if request.offset > 0 { throw URLError(.networkConnectionLost) }
        return .init(state: .ready, generatedAt: 0, records: [self.record("partial")], hasMore: true, nextOffset: 1)
      }, now: Self.now)
      #expect(failed.state == .unavailable)
      #expect(failed.syncedAt == Self.now)
      let samples = try await analytics(service)
      #expect(samples.map(\.sessionID) == ["session-kept"])
    }
  }

  @Test("devices that can't report yet say why, instead of reading as zero")
  func reportsState() async throws {
    try await withService { service in
      let old = await service.collectDeviceUsage(from: endpoint { _ in throw UsageDeviceCollectionError.updateRequired }, now: Self.now)
      #expect(old.state == .updateRequired)
      let scanning = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .init(state: .scanning, generatedAt: 0, records: [], hasMore: false, nextOffset: 0)
      }, now: Self.now)
      #expect(scanning.state == .scanning)
    }
  }

  @Test("a Mac can pass on the remote workspaces it manages, but not ones read directly")
  func relays() async throws {
    try await withService { service in
      let page = UsageDeviceExportPage(
        state: .ready, generatedAt: 0,
        records: [record("own"), record("relayed", device: "host-1"), record("unlisted", device: "stranger")],
        hasMore: false, nextOffset: 3, devices: [Self.host]
      )
      _ = await service.collectDeviceUsage(from: endpoint { _ in page }, now: Self.now)
      let attributed = Dictionary(grouping: try await analytics(service), by: \.usageDeviceID).mapValues(\.count)
      #expect(attributed == ["mac-2": 1, "host-1": 1])
      #expect(await service.storedDeviceSummaries().contains { $0.identity == Self.host })
    }
    try await withService { service in
      let page = UsageDeviceExportPage(
        state: .ready, generatedAt: 0, records: [record("relayed", device: "host-1")],
        hasMore: false, nextOffset: 1, devices: [Self.host]
      )
      _ = await service.collectDeviceUsage(from: endpoint(excludedRelays: ["host-1"]) { _ in page }, now: Self.now)
      let samples = try await analytics(service)
      #expect(samples.isEmpty)
    }
  }

  @Test("identical dedupe keys on two devices both count")
  func dedupesPerDevice() async throws {
    try await withService { service in
      func keyed(_ device: UsageDeviceIdentity) -> UsageDeviceEndpoint {
        endpoint(device) { _ in
          let sample = UsageSample(
            id: "same", provider: .claude, timestamp: Self.now.addingTimeInterval(-3_600), sessionID: "s",
            accountLabel: "A", model: "m", harness: "Claude Code", application: "a",
            tokens: UsageTokenCounts(inputTokens: 5), sourceID: "claude:file:x", sourceEventID: "same", dedupeKey: "shared"
          )
          return .paged([UsageDeviceRecord(sample: sample)], request: .init(since: 0, offset: 0))
        }
      }
      _ = await service.collectDeviceUsage(from: keyed(Self.mac), now: Self.now)
      _ = await service.collectDeviceUsage(from: keyed(Self.host), now: Self.now)
      let samples = try await analytics(service)
      #expect(samples.count == 2)
    }
  }

  @Test("a run watched from this Mac only counts until the host's history covers it")
  func coveredLiveRuns() {
    func sample(_ id: String, source: String, harness: String, hoursAgo: Double = 0, tokens: Int64 = 1) -> UsageSample {
      UsageSample(id: id, provider: .codex, timestamp: Self.now.addingTimeInterval(-hoursAgo * 3_600), sessionID: id,
        accountLabel: "A", model: "m", harness: harness, application: "a", tokens: UsageTokenCounts(inputTokens: tokens), sourceID: source)
    }
    let live = UsageDeviceSource.liveRunsSourceID(deviceID: "host-1")
    let kept = LocalUsageService.suppressWovenMatterEchoes([
      sample("watched-codex", source: live, harness: "Codex"),
      sample("watched-pi", source: live, harness: "Pi Durable", tokens: 7),
      // The host's history hasn't reached this turn yet (its report is behind), so it still counts.
      sample("watched-earlier", source: live, harness: "Codex", hoursAgo: 5),
      sample("scanned", source: UsageDeviceSource.sourceID(deviceID: "host-1"), harness: "Codex"),
    ])
    #expect(kept.map(\.id).sorted() == ["scanned", "watched-earlier", "watched-pi"])
    #expect(sample("x", source: live, harness: "Codex").usageDeviceID == "host-1")
    #expect(sample("x", source: "wovenmatter:local", harness: "Codex").usageDeviceID == UsageDeviceSource.localDeviceID)
    #expect(!sample("x", source: "wovenmatter:local", harness: "Codex").isRemoteLiveRun)
  }

  @Test("a remote turn stored as this Mac's before this version gives way to the host's history")
  func olderRemoteLiveRuns() {
    func sample(_ id: String, session: String, source: String) -> UsageSample {
      UsageSample(id: id, provider: .claude, timestamp: Self.now, sessionID: session, accountLabel: "A", model: "m",
        harness: "Claude Code", application: "a", tokens: UsageTokenCounts(inputTokens: 1), sourceID: source)
    }
    let kept = LocalUsageService.droppingLiveRunsReportedElsewhere([
      sample("old-remote", session: "remote-session", source: "wovenmatter:local"),
      sample("local", session: "local-session", source: "wovenmatter:local"),
      sample("host", session: "remote-session", source: UsageDeviceSource.sourceID(deviceID: "host-1")),
    ])
    #expect(kept.map(\.id).sorted() == ["host", "local"])
  }

  @Test("usage stays after a host deletes its old transcripts, while a Mac's report is complete")
  func retainsHistory() async throws {
    try await withService { service in
      let first = [self.record("old", daysAgo: 60), self.record("recent", daysAgo: 1)]
      let second = [self.record("new", daysAgo: 0.5)]
      let nextDay = Self.now.addingTimeInterval(25 * 60 * 60)
      // The second pass is a full one, reporting neither earlier row.
      _ = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .paged(first, request: .init(since: 0, offset: 0))
      }, now: Self.now)
      _ = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .paged(second, request: .init(since: 0, offset: 0))
      }, now: nextDay)
      #expect(Set(try await analytics(service).map(\.sessionID)) == ["session-old", "session-new"])

      _ = await service.collectDeviceUsage(from: endpoint(keepsLastingHistory: true) { _ in
        .paged(first, request: .init(since: 0, offset: 0))
      }, now: Self.now)
      _ = await service.collectDeviceUsage(from: endpoint(keepsLastingHistory: true) { _ in
        .paged(second, request: .init(since: 0, offset: 0))
      }, now: nextDay)
      let fromMac = try await analytics(service).filter { $0.usageDeviceID == Self.mac.id }
      #expect(fromMac.map(\.sessionID) == ["session-new"])
    }
  }

  @Test("a partial pull exports whole hours, so it can't replace an hour with part of its total")
  func exportsWholeHours() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-devices-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "usage.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: database)
    let hour = try #require(Calendar.current.dateInterval(of: .hour, for: Self.now.addingTimeInterval(-7_200))).start
    for (run, minutes) in [("early", 10.0), ("late", 40.0)] {
      try await recorder.record(.init(
        runID: run, timestamp: hour.addingTimeInterval(minutes * 60), runtimeKind: .codex, sessionID: "s", model: "gpt-5.5",
        reasoningLevel: nil, agent: nil, workspace: nil, tokens: UsageTokenCounts(inputTokens: 9), costUSD: nil
      ))
    }
    let service = Self.service(home: directory, database: database)
    _ = try await analytics(service)
    let since = hour.addingTimeInterval(30 * 60).timeIntervalSince1970
    let page = try await service.deviceExport(.init(since: since, offset: 0), now: Self.now)
    #expect(page.records.map(\.inputTokens) == [18])
  }

  @Test("a Mac reports that it is still reading until its first full import finishes")
  func exportWaitsForFirstImport() async throws {
    try await withService { service in
      #expect(try await service.deviceExport(.init(since: 0, offset: 0), now: Self.now).state == .scanning)
      _ = try await analytics(service)
      #expect(try await service.deviceExport(.init(since: 0, offset: 0), now: Self.now).state == .ready)
    }
  }

  @Test("an exported hour keeps its ID as more calls land in it")
  func exportIDsAreStable() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-devices-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "usage.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: database)
    let hour = try #require(Calendar.current.dateInterval(of: .hour, for: Self.now.addingTimeInterval(-7_200))).start
    func run(_ id: String, minutes: Double) async throws {
      try await recorder.record(.init(
        runID: id, timestamp: hour.addingTimeInterval(minutes * 60), runtimeKind: .codex, sessionID: "s", model: "gpt-5.5",
        reasoningLevel: nil, agent: nil, workspace: nil, tokens: UsageTokenCounts(inputTokens: 9), costUSD: nil
      ))
    }
    let service = Self.service(home: directory, database: database)
    try await run("first", minutes: 10)
    _ = try await analytics(service)
    let before = try await service.deviceExport(.init(since: 0, offset: 0), now: Self.now).records
    try await run("second", minutes: 40)
    let after = try await service.deviceExport(.init(since: 0, offset: 0), now: Self.now).records
    #expect(before.count == 1)
    #expect(after.map(\.id) == before.map(\.id))
    #expect(after.map(\.inputTokens) == [18])
  }

  @Test("a host's rows passed on by a Mac keep the host's IDs, so a direct read replaces them")
  func relayedRowsKeepHostIDs() async throws {
    try await withService { service in
      _ = try await analytics(service)
      _ = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .paged([self.record("hour-1", daysAgo: 10), self.record("hour-2")], request: .init(since: 0, offset: 0))
      }, now: Self.now)
      let direct = [record("hour-1", daysAgo: 10), record("hour-2")].map(\.id)
      let relayed = try await service.deviceExport(.init(since: 0, offset: 0), relaying: [Self.host], now: Self.now)
      #expect(relayed.records.map(\.id).sorted() == direct.sorted())
      #expect(relayed.records.allSatisfy { $0.device == Self.host.id })
    }
  }

  @Test("a host that lost part of an older hour can't shrink what was stored for it")
  func olderHostRowsNeverShrink() async throws {
    try await withService { service in
      _ = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .paged([self.record("old", tokens: 100, daysAgo: 10), self.record("recent", tokens: 100)], request: .init(since: 0, offset: 0))
      }, now: Self.now)
      _ = await service.collectDeviceUsage(from: endpoint(Self.host) { _ in
        .paged([self.record("old", tokens: 40, daysAgo: 10), self.record("recent", tokens: 60)], request: .init(since: 0, offset: 0))
      }, now: Self.now)
      let tokens = Dictionary(uniqueKeysWithValues: try await analytics(service).map { ($0.sessionID, $0.tokens.inputTokens) })
      #expect(tokens == ["session-old": 100, "session-recent": 60])
    }
  }

  @Test("a record's ID is stable and never carries the transcript's path")
  func recordIDsHidePaths() {
    #expect(!record("a").id.contains("secret"))
    #expect(record("a").id == record("a").id)
    #expect(record("a").id != record("b").id)
  }

  @Test("a device's row finds its usage even when its ID holds a separator")
  func summaryMatchesSamples() throws {
    let identity = UsageDeviceIdentity(id: "ios:device", name: "iPad", kind: .ios)
    let sample = try #require(record("a").sample(deviceID: identity.id))
    #expect(UsageDeviceSummary(identity: identity, state: .synced).id == sample.usageDeviceID)
  }

  @Test("tools and phones still see runs this Mac watched on a remote workspace")
  func recordedSamplesKeepWatchedRuns() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-devices-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "usage.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: database)
    try await recorder.record(.init(
      runID: "watched", timestamp: Self.now.addingTimeInterval(-60), runtimeKind: .codex, sessionID: "s", model: "gpt-5.5",
      reasoningLevel: nil, agent: nil, workspace: nil, tokens: UsageTokenCounts(inputTokens: 9), costUSD: nil,
      remoteWorkspaceID: Self.host.id
    ))
    let service = Self.service(home: directory, database: database)
    let recorded = try await service.recordedSamples(from: .usageHistoryStart, to: Self.now)
    #expect(recorded.map(\.sessionID) == ["s"])
  }

  @Test("tools and phones keep reading only this Mac's records")
  func recordedSamplesStayLocal() async throws {
    try await withService { service in
      _ = await service.collectDeviceUsage(from: endpoint { _ in
        .paged([self.record("remote")], request: .init(since: 0, offset: 0))
      }, now: Self.now)
      let recorded = try await service.recordedSamples(from: .usageHistoryStart, to: Self.now)
      #expect(recorded.isEmpty)
    }
  }

  @Test("an export holds counts and folder names, never paths, and skips other Macs' usage")
  func exportIsRedacted() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-devices-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appending(path: "usage.sqlite")
    let recorder = try await UsageRunRecorder(databaseURL: database)
    try await recorder.record(.init(
      runID: "run", timestamp: Self.now.addingTimeInterval(-60), runtimeKind: .codex, sessionID: "s", model: "gpt-5.5",
      reasoningLevel: nil, agent: nil, workspace: "/srv/someone/private/client-project",
      tokens: UsageTokenCounts(inputTokens: 9), costUSD: nil
    ))
    let service = Self.service(home: directory, database: database)
    _ = try await analytics(service)
    _ = await service.collectDeviceUsage(from: endpoint { _ in
      .paged([self.record("from-peer"), self.record("from-host", device: "host-1")], request: .init(since: 0, offset: 0))
    }, now: Self.now)
    let page = try await service.deviceExport(.init(since: 0, offset: 0), now: Self.now)
    #expect(page.records.count == 1)
    #expect(page.records.first?.workspace == "client-project")
    #expect(page.records.first?.device == nil)
    let wire = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
    #expect(!wire.contains("/srv/someone"))
  }

  @Test("out-of-bounds values from another device are dropped")
  func rejectsBadRecords() throws {
    let json = #"""
      {"id":"a","timestamp":1790000000,"provider":"codex","sessionID":"s","accountLabel":"Unknown","model":"m",
       "billingProvider":"p","billingRoute":"r","harness":"h","application":"a","inputTokens":-1,"cachedInputTokens":0,
       "cacheCreationTokens":0,"outputTokens":0,"reasoningTokens":0,"totalTokens":0,"requestCount":1}
      """#
    let bad = try JSONDecoder().decode(UsageDeviceRecord.self, from: Data(json.utf8))
    #expect(bad.sample(deviceID: "x") == nil)
  }

  @Test("the remote scanner's page format decodes")
  func decodesRemotePage() throws {
    let json = #"""
      {"state":"ready","generatedAt":1790000000.5,"hasMore":false,"nextOffset":1,"records":[
       {"id":"abc","timestamp":1790000000,"provider":"claude","sessionID":"s","accountLabel":"Unknown","model":"claude-opus-4-8",
        "billingProvider":"Anthropic","billingRoute":"Claude account","reasoningLevel":null,"harness":"Claude Code",
        "application":"Claude Code","agent":null,"workspace":"app","inputTokens":5,"cachedInputTokens":7,"cacheCreationTokens":2,
        "outputTokens":3,"reasoningTokens":0,"totalTokens":17,"requestCount":2,"costUSD":null,"dedupeKey":null}]}
      """#
    let page = try JSONDecoder().decode(UsageDeviceExportPage.self, from: Data(json.utf8))
    let sample = try #require(page.records.first?.sample(deviceID: "host-1"))
    #expect(sample.provider == .claude)
    #expect(sample.tokens.totalTokens == 17)
    #expect(sample.requestCount == 2)
    #expect(sample.usageDeviceID == "host-1")
  }

  @Test("iPhone and iPad records become usage, keeping the newest revision of a message")
  func readsPiDurableRecords() throws {
    func stored(_ id: String, input: Int) throws -> StoredNativeRecord {
      let root: [String: Any] = ["id": 1, "conversationId": 2, "model": [
        ["role": "user", "content": "private question"],
        ["role": "assistant", "provider": "openrouter", "model": "kimi-k2", "timestamp": 1_790_000_000_000.0,
         "usage": ["input": input, "output": 2, "cacheRead": 3, "cacheWrite": 0], "content": "private answer"],
      ]]
      return .init(recordID: id, conversationID: "conversation", data: try JSONSerialization.data(withJSONObject: root))
    }
    let records = PiDurableUsageRecords.records(from: [try stored("old", input: 1), try stored("new", input: 10)])
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.inputTokens == 10)
    #expect(record.provider == "openrouter")
    #expect(record.harness == "Pi Durable")
    #expect(!String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("private"))
  }

  @Test("a compressed session keeps its identity and yields marked lines with real numbers")
  func compressedTranscripts() throws {
    let plain = URL(fileURLWithPath: "/tmp/a/session.jsonl")
    let compressed = URL(fileURLWithPath: "/tmp/a/session.jsonl.zst")
    let other = URL(fileURLWithPath: "/tmp/a/other.jsonl.zst")
    #expect(UsageCompressedTranscript.identityPath(compressed) == plain.path)
    #expect(UsageCompressedTranscript.isTranscript(compressed))
    #expect(!UsageCompressedTranscript.isTranscript(URL(fileURLWithPath: "/tmp/a/session.zst")))
    let node = URL(fileURLWithPath: "/usr/bin/true")
    #expect(UsageCompressedTranscript.preferred([plain, compressed, other], node: node) == [plain, other])
    #expect(UsageCompressedTranscript.preferred([compressed], node: nil).isEmpty)
    // This small fixture says: line one\nmarker two\nline three\nmarker four\n
    let fixture = Data(base64Encoded: "KLUv/SArNQEA6GxpbmUgb25lCm1hcmtlciB0d28KdGhyZWZvdXIKAgA5i7hrMgE=")
    guard let fixture, let nodePath = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":").map({ URL(fileURLWithPath: String($0)).appending(path: "node") })
      .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-zst-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "session.jsonl.zst")
    try fixture.write(to: file)
    var lines: [(Int, String)] = []
    try UsageCompressedTranscript.forEachMarkedLine(in: file, markers: ["marker"], node: nodePath, check: {}) { data, number in
      lines.append((number, String(decoding: data, as: UTF8.self)))
    }
    #expect(lines.map(\.0) == [2, 4])
    #expect(lines.map(\.1) == ["marker two", "marker four"])
  }
}
