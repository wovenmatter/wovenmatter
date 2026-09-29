import Foundation
import Darwin
import SQLite3
import WovenMatterCore
import WovenMatterClient

/// Filesystem work has its own bounded lane. The shared database writer sees
/// only prepared values, with one atomic replacement per source.
actor UsageTranscriptImporter {
  struct Outcome: Sendable {
    let failures: Int
    static let empty = Outcome(failures: 0)
  }
  private static let parserVersion = "usage-index-v3"
  let homeDirectory: URL
  private static let sharedPreparationWorker = DatabaseWorker(label: "wovenmatter.usage.import", capacity: 4)
  private let ownership: UsageRefreshOwnership
  private let preparationWorker: DatabaseWorker
  private(set) var importOutcomes: [String: Outcome]
  private var hadSourceFailures = false

  init(homeDirectory: URL, outcomes: [String: Outcome], ownership: UsageRefreshOwnership,
    preparationWorker: DatabaseWorker? = nil) {
    self.homeDirectory = homeDirectory
    self.ownership = ownership
    self.preparationWorker = preparationWorker ?? Self.sharedPreparationWorker
    importOutcomes = outcomes
  }
  func run(
    store: AsyncUsageStore,
    cutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) async throws -> Bool {
    hadSourceFailures = false
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
      let codexRoot = homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
      importOutcomes["codex:file:"] = try await importTranscriptFiles(
        root: codexRoot,
        prefix: "codex:file:",
        sourceName: "Codex rollout",
        provider: .codex,
        harness: "Codex",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url, check in
        var state = CodexUsageScanState()
        var records: [UsageSample] = []
        let usageMarker = Data("\"token_count\"".utf8)
        let contextMarker = Data("\"turn_context\"".utf8)
        let metadataMarker = Data("\"session_meta\"".utf8)
        try Self.forEachLineData(in: url, check: check) { data, lineNumber in
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
        try Self.forEachLineData(in: url, check: check) { data, lineNumber in
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

    if !enabledProviders.isEmpty {
      let piRoot = homeDirectory.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory)
      importOutcomes["pi:file:"] = try await importHarnessFiles(
        root: piRoot,
        prefix: "pi:file:",
        harness: "Pi",
        enabledProviders: enabledProviders,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      )

      let openClawRoot = homeDirectory.appending(
        path: ".openclaw/agents",
        directoryHint: .isDirectory
      )
      importOutcomes["openclaw:file:"] = try await importHarnessFiles(
        root: openClawRoot,
        prefix: "openclaw:file:",
        harness: "OpenClaw",
        enabledProviders: enabledProviders,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        url.path.contains("/sessions/")
          && url.lastPathComponent.hasSuffix(".jsonl")
          && !url.lastPathComponent.hasSuffix(".trajectory.jsonl")
      }

      let hermesDatabase = homeDirectory.appending(path: ".hermes/state.db")
      importOutcomes["hermes:database"] = try await importDatabase(
        databaseURL: hermesDatabase,
        sourceID: "hermes:database",
        sourceName: "Hermes usage ledger",
        provider: .unknown,
        harness: "Hermes",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter, check in
        try HermesUsageDatabase(databaseURL: hermesDatabase)
          .samples(cutoff: indexedAfter, now: now, check: check)
          .filter { enabledProviders.contains($0.provider) }
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
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter, check in
        try OpenCodeUsageDatabase(databaseURL: openCodeDatabase)
          .samples(cutoff: indexedAfter, now: now, check: check)
          .filter { $0.provider == .openCodeGo }
      }
    }
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
    predicate: @escaping @Sendable (URL) -> Bool = { $0.pathExtension == "jsonl" },
    fingerprint: (@Sendable (URL) throws -> String)? = nil,
    parser: @escaping @Sendable (URL, @escaping @Sendable () throws -> Void) throws -> [UsageSample]
  ) async throws -> Outcome {
    let files = try await prepare { check in
      try Self.files(root: root, cutoff: cutoff, predicate: predicate, check: check)
    }
    var failures = 0
    for file in files {
      try ownership.check()
      do {
        let sourceID = prefix + file.path
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

  private func importHarnessFiles(
    root: URL,
    prefix: String,
    harness: String,
    enabledProviders: Set<ProviderKind>,
    providerFilterSignature: String,
    store: AsyncUsageStore,
    cutoff: Date,
    now: Date,
    predicate: @escaping @Sendable (URL) -> Bool = { $0.pathExtension == "jsonl" }
  ) async throws -> Outcome {
    try await importTranscriptFiles(
      root: root,
      prefix: prefix,
      sourceName: "\(harness) session",
      provider: .unknown,
      harness: harness,
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: predicate
    ) { url, check in
      var state = HarnessUsageScanState()
      var records: [UsageSample] = []
      let usageMarker = Data("\"usage\"".utf8)
      let modelMarker = Data("\"model_change\"".utf8)
      let thinkingMarker = Data("\"thinking_level_change\"".utf8)
      let sessionMarker = Data("\"session\"".utf8)
      try Self.forEachLineData(in: url, check: check) { data, lineNumber in
        guard data.range(of: usageMarker) != nil
                || data.range(of: modelMarker) != nil
                || data.range(of: thinkingMarker) != nil
                || data.range(of: sessionMarker) != nil else { return }
        if let parsed = LocalUsageTranscriptParser.parseHarness(
          line: String(decoding: data, as: UTF8.self),
          lineNumber: lineNumber,
          harness: harness,
          state: &state
        ) {
          records.append(parsed)
        }
      }
      return records.filter { enabledProviders.contains($0.provider) }
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
            values.isRegularFile == true,
            (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
      result.append(url)
    }
    return result.sorted { $0.path < $1.path }
  }

  nonisolated private static func forEachLineData(
    in url: URL,
    check: () throws -> Void,
    body: (Data.SubSequence, Int) throws -> Void
  ) throws {
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
