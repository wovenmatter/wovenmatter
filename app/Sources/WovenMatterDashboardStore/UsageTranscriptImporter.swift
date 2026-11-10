import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore
import WovenMatterClient

/// Filesystem work has its own bounded lane. The shared database writer sees
/// only prepared values, with one atomic replacement per source.
actor UsageTranscriptImporter {
  struct Outcome: Sendable {
    let failures: Int
    static let empty = Outcome(failures: 0)
  }
  private static let parserVersion = "usage-index-v4"
  let homeDirectory: URL
  /// This Mac's library database, which also holds the default agent's Pi Durable stores.
  /// Bots keep theirs beside it, in `Bots/data/bots.sqlite`.
  let libraryDatabaseURL: URL?
  private static let sharedPreparationWorker = DatabaseWorker(label: "wovenmatter.usage.import", capacity: 4)
  private let ownership: UsageRefreshOwnership
  private let preparationWorker: DatabaseWorker
  private(set) var importOutcomes: [String: Outcome]
  private var hadSourceFailures = false
  private var batch: Batch?

  /// Limits one pass to files last changed in this window. A file's whole history is
  /// read at once, so widening the window never reads the same file twice.
  struct Batch: Sendable {
    let modifiedAfter: Date
    let modifiedBefore: Date?
  }

  init(homeDirectory: URL, outcomes: [String: Outcome], ownership: UsageRefreshOwnership,
    preparationWorker: DatabaseWorker? = nil, libraryDatabaseURL: URL? = nil) {
    self.homeDirectory = homeDirectory
    self.libraryDatabaseURL = libraryDatabaseURL
    self.ownership = ownership
    self.preparationWorker = preparationWorker ?? Self.sharedPreparationWorker
    importOutcomes = outcomes
  }
  func run(
    store: AsyncUsageStore,
    cutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date,
    batch: Batch? = nil
  ) async throws -> Bool {
    hadSourceFailures = false
    self.batch = batch
    try await importLocalSources(store: store, cutoff: cutoff, enabledProviders: enabledProviders, now: now)
    importOutcomes.removeValue(forKey: "wovenmatter:index")
    // A failed or concurrently changed source must not advance range coverage.
    // Its prior source checkpoint remains intact and the next refresh retries.
    return !hadSourceFailures
  }

  private func importLocalSources(
    store: AsyncUsageStore,
    cutoff retentionCutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) async throws {
    let providerFilterSignature = enabledProviders
      .map(\.rawValue)
      .sorted()
      .joined(separator: ",")

    if enabledProviders.contains(.codex) {
      // Codex moves a chat it archives into archived_sessions. Its replies keep their
      // identity there, so a chat read before and after the move is one record.
      for (folder, key, name) in [("sessions", "codex:file:", "Codex rollout"),
                                  ("archived_sessions", "codex:archived:", "Archived Codex rollout")] {
        importOutcomes[key] = try await importTranscriptFiles(
          root: homeDirectory.appending(path: ".codex/" + folder, directoryHint: .isDirectory),
          prefix: "codex:file:",
          sourceName: name,
          provider: .codex,
          harness: "Codex",
          providerFilterSignature: providerFilterSignature,
          store: store,
          cutoff: retentionCutoff,
          now: now,
          parser: Self.codexSamples
        )
      }
    }

    if enabledProviders.contains(.claude) {
      let claudeRoot = homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)
      importOutcomes["claude:file:"] = try await importTranscriptFiles(
        root: claudeRoot,
        prefix: "claude:file:",
        sourceName: "Claude transcript",
        provider: .claude,
        harness: "Claude Code",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url, check in
        var records: [UsageSample] = []
        let usageMarker = Data("\"usage\"".utf8)
        try Self.forEachLineData(in: url, markers: ["\"usage\""], check: check) { data, lineNumber in
          guard data.range(of: usageMarker) != nil else { return }
          if let parsed = LocalUsageTranscriptParser.parseClaude(
            line: String(decoding: data, as: UTF8.self),
            lineNumber: lineNumber
          ) {
            records.append(parsed)
          }
        }
        return records
      }
    }

    if enabledProviders.contains(.grok) {
      let grokRoot = homeDirectory.appending(path: ".grok/sessions", directoryHint: .isDirectory)
      importOutcomes["grok:file:"] = try await importGrok(
        root: grokRoot,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      )
    }

    if enabledProviders.contains(.openCodeGo) {
      let openCodeDatabase = homeDirectory.appending(path: ".local/share/opencode/opencode.db")
      importOutcomes["opencode:database"] = try await importDatabase(
        databaseURL: openCodeDatabase,
        sourceID: "opencode:database",
        sourceName: "OpenCode history",
        provider: .openCodeGo,
        harness: "OpenCode",
        providerFilterSignature: providerFilterSignature,
        store: store,
        // A database has no files to batch, so its read window widens instead.
        cutoff: max(batch?.modifiedAfter ?? retentionCutoff, retentionCutoff),
        now: now
      ) { indexedAfter, check in
        try OpenCodeUsageDatabase(databaseURL: openCodeDatabase)
          .samples(cutoff: indexedAfter, now: now, check: check)
      }
    }

    try await importPiSources(
      enabledProviders: enabledProviders,
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: retentionCutoff,
      now: now
    )
  }

  /// Pi on this Mac: the Pi CLI's sessions, and Pi Durable (the default agent and bots)
  /// in each place it has kept history. A reply found in more than one of them keeps
  /// one identity (`PiDurableUsageRecords`), so it counts once.
  private func importPiSources(
    enabledProviders: Set<ProviderKind>,
    providerFilterSignature: String,
    store: AsyncUsageStore,
    cutoff: Date,
    now: Date
  ) async throws {
    let enabled: @Sendable (UsageSample) -> Bool = { enabledProviders.contains($0.provider) }
    // Stored as "Pi" (row identities use it) and shown as "Pi CLI".
    importOutcomes["pi:file:"] = try await importTranscriptFiles(
      root: homeDirectory.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory),
      prefix: "pi:file:",
      sourceName: "Pi session",
      provider: .unknown,
      harness: "Pi",
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: { $0.pathExtension == "jsonl" }
    ) { url, check in
      try Self.piSessionSamples(url, harness: "Pi", check: check).filter(enabled)
    }

    let agent = homeDirectory.appending(path: ".wovenmatter/default-agent", directoryHint: .isDirectory)
    var failures = 0
    // The default agent's sessions from before Pi Durable used Pi's session files.
    let presessions = try await importTranscriptFiles(
      root: agent.appending(path: "sessions", directoryHint: .isDirectory),
      prefix: "pi-durable:file:",
      sourceName: "Pi Durable session",
      provider: .unknown,
      harness: PiDurableUsageRecords.harness,
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: { $0.pathExtension == "jsonl" }
    ) { url, check in
      try Self.piSessionSamples(url, harness: "Pi", check: check).map(PiDurableUsageRecords.adopting).filter(enabled)
    }
    failures += presessions.failures
    // Later sessions kept one commit log per session, which stays as a backup once
    // the session moves into SQLite.
    let commitLogs = try await importTranscriptFiles(
      root: agent.appending(path: "durable", directoryHint: .isDirectory),
      prefix: "pi-durable:file:",
      sourceName: "Pi Durable session",
      provider: .unknown,
      harness: PiDurableUsageRecords.harness,
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: { $0.lastPathComponent == "main.jsonl" && $0.deletingLastPathComponent().lastPathComponent == "native" }
    ) { url, check in
      let session = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
      return PiDurableUsageRecords.samples(
        entries: try PiDurableUsageRecords.legacyEntries(in: url, check: check),
        session: .init(id: session, sourceID: "pi-durable:file:" + url.path)
      ).filter(enabled)
    }
    failures += commitLogs.failures
    // SQLite stores: the library database (Woven's own runs), the default agent's own
    // database, and the bots runtime's.
    var databases = [agent.appending(path: "workspace.sqlite")]
    if let libraryDatabaseURL {
      databases.insert(libraryDatabaseURL, at: 0)
      databases.append(libraryDatabaseURL.deletingLastPathComponent().appending(path: "Bots/data/bots.sqlite"))
    }
    for database in databases where FileManager.default.fileExists(atPath: database.path) {
      // One source per store, so a deleted session or purged bot keeps its history here.
      let stores: [PiDurableUsageDatabase.Store]
      do {
        stores = try await prepare { check in
          try PiDurableUsageDatabase(databaseURL: database, sourceID: "").stores(check: check)
        }
      } catch is CancellationError { throw CancellationError() }
      catch let error as DatabaseWorkerError { throw error }
      catch { failures += 1; hadSourceFailures = true; continue }
      for piStore in stores {
        let sourceID = "pi-durable:database:" + database.path + "#" + piStore.prefix
        let outcome = try await importDatabase(
          databaseURL: database,
          sourceID: sourceID,
          sourceName: piStore.isBot ? "Bot history" : "Pi Durable history",
          provider: .unknown,
          harness: PiDurableUsageRecords.harness,
          providerFilterSignature: providerFilterSignature,
          store: store,
          cutoff: max(batch?.modifiedAfter ?? cutoff, cutoff),
          now: now
        ) { indexedAfter, check in
          try PiDurableUsageDatabase(databaseURL: database, sourceID: sourceID)
            .samples(store: piStore, cutoff: indexedAfter, now: now, check: check).filter(enabled)
        }
        failures += outcome.failures
      }
    }
    importOutcomes["pi-durable:"] = Outcome(failures: failures)
  }

  nonisolated private static func piSessionSamples(
    _ url: URL, harness: String, check: @escaping @Sendable () throws -> Void
  ) throws -> [UsageSample] {
    var state = HarnessUsageScanState()
    var records: [UsageSample] = []
    let markers = ["\"usage\"", "\"model_change\"", "\"thinking_level_change\"", "\"session\""].map { Data($0.utf8) }
    try Self.forEachLineData(in: url, check: check) { data, lineNumber in
      guard markers.contains(where: { data.range(of: $0) != nil }) else { return }
      if let parsed = LocalUsageTranscriptParser.parseHarness(
        line: String(decoding: data, as: UTF8.self),
        lineNumber: lineNumber,
        harness: harness,
        state: &state
      ) {
        records.append(parsed)
      }
    }
    return records
  }

  nonisolated private static func codexSamples(
    _ url: URL, check: @escaping @Sendable () throws -> Void
  ) throws -> [UsageSample] {
    var state = CodexUsageScanState()
    var records: [UsageSample] = []
    let usageMarker = Data("\"token_count\"".utf8)
    let contextMarker = Data("\"turn_context\"".utf8)
    let metadataMarker = Data("\"session_meta\"".utf8)
    let markers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""]
    try Self.forEachLineData(in: url, markers: markers, check: check) { data, lineNumber in
      guard data.range(of: usageMarker) != nil
              || data.range(of: contextMarker) != nil
              || data.range(of: metadataMarker) != nil else { return }
      if let sample = LocalUsageTranscriptParser.parseCodex(
        line: String(decoding: data, as: UTF8.self),
        lineNumber: lineNumber,
        state: &state
      ) {
        records.append(sample)
      }
    }
    return records
  }

  private struct PreparedSource: Sendable {
    let fingerprint: String
    let indexedAfter: Date
    let samples: [UsageSample]
  }

  private func prepare<T: Sendable>(
    _ operation: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> T
  ) async throws -> T {
    let ownership = ownership
    return try await preparationWorker.perform(timeout: 300, interruptible: true) { context in
      let check: @Sendable () throws -> Void = { try context.check(); try ownership.check() }
      try check()
      return try operation(check)
    }
  }

  private func importTranscriptFiles(
    root: URL,
    prefix: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    providerFilterSignature: String,
    store: AsyncUsageStore,
    cutoff: Date,
    now: Date,
    predicate: @escaping @Sendable (URL) -> Bool = { UsageCompressedTranscript.isTranscript($0) },
    fingerprint: (@Sendable (URL) throws -> String)? = nil,
    parser: @escaping @Sendable (URL, @escaping @Sendable () throws -> Void) throws -> [UsageSample]
  ) async throws -> Outcome {
    let batch = batch
    let files = try await prepare { check in
      try Self.files(
        root: root,
        cutoff: batch?.modifiedAfter ?? cutoff,
        before: batch?.modifiedBefore,
        predicate: predicate,
        check: check
      )
    }
    var failures = 0
    for file in files {
      try ownership.check()
      do {
        let sourceID = prefix + UsageCompressedTranscript.identityPath(file)
        let stored = try await store.source(sourceID)
        let prepared = try await prepare { check -> PreparedSource? in
          let currentFingerprint = try (fingerprint?(file) ?? Self.fileFingerprint(file)) + ":" + providerFilterSignature
          let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
          guard stored?.fingerprint != currentFingerprint
                  || stored?.indexedAfter == nil
                  || (stored?.indexedAfter ?? .distantFuture) > cutoff else { return nil }
          let samples = try parser(file, check).filter { $0.timestamp >= indexedAfter && $0.timestamp <= now }
          try check()
          return PreparedSource(fingerprint: currentFingerprint, indexedAfter: indexedAfter,
            samples: Self.uniqueSourceEvents(samples))
        }
        guard let prepared else { continue }
        try await replace(prepared, expected: stored, sourceID: sourceID, sourceName: sourceName,
          location: abbreviated(file), provider: provider, harness: harness, store: store, now: now)
      } catch is CancellationError { throw CancellationError() }
      catch let error as DatabaseWorkerError { throw error }
      catch { failures += 1 }
    }
    if failures > 0 { hadSourceFailures = true }
    return Outcome(failures: failures)
  }

  private func replace(_ prepared: PreparedSource, expected: UsageStoredSource?, sourceID: String,
    sourceName: String, location: String, provider: ProviderKind, harness: String,
    store: AsyncUsageStore, now: Date) async throws {
    let ownership = ownership
    try await store.write(validating: { try ownership.check() }) { connection in
      // Another service may have indexed a wider range while parsing. Preserve
      // its committed data and retry this source on the next refresh.
      try connection.performTransaction {
        guard try connection.source(sourceID) == expected else {
          throw UsageStoreError.step("The usage source changed during preparation")
        }
        try connection.replace(sourceID: sourceID, sourceName: sourceName, location: location,
          provider: provider, harness: harness, fingerprint: prepared.fingerprint,
          samples: prepared.samples, importedAt: now, indexedAfter: prepared.indexedAfter, transactional: false)
      }
    }
  }

  private func importGrok(
    root: URL,
    providerFilterSignature: String,
    store: AsyncUsageStore,
    cutoff: Date,
    now: Date
  ) async throws -> Outcome {
    try await importTranscriptFiles(
      root: root,
      prefix: "grok:file:",
      sourceName: "Grok session",
      provider: .grok,
      harness: "Grok Build",
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: { $0.lastPathComponent == "updates.jsonl" },
      fingerprint: { try Self.grokFingerprint($0) }
    ) { url, check in
      let summaryURL = url.deletingLastPathComponent().appending(path: "summary.json")
      let summary: [String: Any]
      if let data = try? Data(contentsOf: summaryURL),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        summary = object
      } else {
        summary = [:]
      }
      var records: [UsageSample] = []
      let usageMarker = Data("\"usage\"".utf8)
      try Self.forEachLineData(in: url, check: check) { data, lineNumber in
        guard data.range(of: usageMarker) != nil else { return }
        records += LocalUsageTranscriptParser.parseGrok(
          line: String(decoding: data, as: UTF8.self),
          lineNumber: lineNumber,
          summary: summary
        )
      }
      return records
    }
  }

  private func importDatabase(
    databaseURL: URL,
    sourceID: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    providerFilterSignature: String,
    store: AsyncUsageStore,
    cutoff: Date,
    now: Date,
    reader: @escaping @Sendable (Date, @escaping @Sendable () throws -> Void) throws -> [UsageSample]
  ) async throws -> Outcome {
    try ownership.check()
    do {
      let stored = try await store.source(sourceID)
      let prepared = try await prepare { check -> PreparedSource? in
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let fingerprint = try Self.databaseFingerprint(databaseURL) + ":" + providerFilterSignature
        let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
        guard stored?.fingerprint != fingerprint || stored?.indexedAfter == nil
          || (stored?.indexedAfter ?? .distantFuture) > cutoff else { return nil }
        let samples = try reader(indexedAfter, check).filter { $0.timestamp >= indexedAfter && $0.timestamp <= now }
        try check()
        return PreparedSource(fingerprint: fingerprint, indexedAfter: indexedAfter,
          samples: Self.uniqueSourceEvents(samples))
      }
      if let prepared {
        try await replace(prepared, expected: stored, sourceID: sourceID, sourceName: sourceName,
          location: abbreviated(databaseURL), provider: provider, harness: harness, store: store, now: now)
      }
      return Outcome(failures: 0)
    } catch is CancellationError { throw CancellationError() }
    catch let error as DatabaseWorkerError { throw error }
    catch {
      hadSourceFailures = true
      return Outcome(failures: 1)
    }
  }

  nonisolated private static func fileFingerprint(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return [
      Self.parserVersion,
      String(values.fileSize ?? 0),
      String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
    ].joined(separator: ":")
  }

  nonisolated private static func databaseFingerprint(_ url: URL) throws -> String {
    var values = [try fileFingerprint(url)]
    for suffix in ["-wal", "-shm"] {
      let sidecar = URL(fileURLWithPath: url.path + suffix)
      if FileManager.default.fileExists(atPath: sidecar.path) {
        values.append(try fileFingerprint(sidecar))
      }
    }
    return values.joined(separator: "|")
  }

  nonisolated private static func grokFingerprint(_ updatesURL: URL) throws -> String {
    var values = [try fileFingerprint(updatesURL)]
    let summaryURL = updatesURL.deletingLastPathComponent().appending(path: "summary.json")
    if FileManager.default.fileExists(atPath: summaryURL.path) {
      values.append(try fileFingerprint(summaryURL))
    }
    return values.joined(separator: "|")
  }

  nonisolated private static func files(
    root: URL,
    cutoff: Date,
    before: Date? = nil,
    predicate: (URL) -> Bool,
    check: () throws -> Void
  ) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator {
      try check()
      guard predicate(url) else { continue }
      guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true else { continue }
      let modified = values.contentModificationDate ?? .distantPast
      guard modified >= cutoff, before.map({ modified < $0 }) ?? true else { continue }
      result.append(url)
    }
    return UsageCompressedTranscript.preferred(result, node: UsageCompressedTranscript.bundledNode)
      .sorted { $0.path < $1.path }
  }

  nonisolated private static func forEachLineData(
    in url: URL,
    markers: [String] = [],
    check: () throws -> Void,
    body: (Data.SubSequence, Int) throws -> Void
  ) throws {
    if UsageCompressedTranscript.isCompressed(url) {
      guard let node = UsageCompressedTranscript.bundledNode else { return }
      try UsageCompressedTranscript.forEachMarkedLine(in: url, markers: markers, node: node, check: check, body: body)
      return
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var start = 0
      var lineNumber = 0
      while start < rawBuffer.count {
        try check()
        let remaining = rawBuffer.count - start
        let newlinePointer = Darwin.memchr(base.advanced(by: start), 0x0A, remaining)
        let end: Int
        if let newlinePointer {
          end = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
        } else {
          end = rawBuffer.count
        }
        lineNumber += 1
        try body(data[start..<end], lineNumber)
        guard end < rawBuffer.count else { return }
        start = end + 1
      }
    }
  }

  nonisolated private static func uniqueSourceEvents(_ samples: [UsageSample]) -> [UsageSample] {
    var seen: Set<String> = []
    return samples.filter { seen.insert($0.sourceEventID).inserted }
  }

  private func abbreviated(_ url: URL) -> String {
    let home = homeDirectory.path
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }
}


/// Interrupt external history queries on the preparation lane, without exposing
/// SQLite handles or transcript contents to the actor or shared writer.
final class UsageSourceQueryCancellation {
  private let check: @Sendable () throws -> Void
  init(_ check: @escaping @Sendable () throws -> Void) { self.check = check }

  func install(on database: OpaquePointer) {
    sqlite3_progress_handler(database, 1_000, { pointer in
      guard let pointer else { return 0 }
      do {
        try Unmanaged<UsageSourceQueryCancellation>.fromOpaque(pointer).takeUnretainedValue().check()
        return 0
      } catch { return 1 }
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func remove(from database: OpaquePointer) {
    sqlite3_progress_handler(database, 0, nil, nil)
  }
}
