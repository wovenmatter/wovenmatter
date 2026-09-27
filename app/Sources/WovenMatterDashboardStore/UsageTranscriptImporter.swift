import Foundation
import Darwin
import WovenMatterCore
import WovenMatterClient

/// Constructed and used only on the usage writer worker. Filesystem parsing and
/// the complete import transaction stay off actors and the UI thread.
final class UsageTranscriptImporter {
  struct Outcome: Sendable {
    let failures: Int
    static let empty = Outcome(failures: 0)
  }
  private static let parserVersion = "usage-index-v3"
  let homeDirectory: URL
  let fileManager: FileManager
  var importOutcomes: [String: Outcome]

  init(homeDirectory: URL, fileManager: FileManager, outcomes: [String: Outcome]) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    importOutcomes = outcomes
  }
  func run(
    store: UsageStore,
    cutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) -> Bool {
    do {
      try store.performTransaction {
        importLocalSourcesWithinTransaction(
          store: store,
          cutoff: cutoff,
          enabledProviders: enabledProviders,
          now: now
        )
      }
      importOutcomes.removeValue(forKey: "wovenmatter:index")
      return true
    } catch {
      importOutcomes["wovenmatter:index"] = Outcome(
        failures: 1
      )
      return false
    }
  }

  private func importLocalSourcesWithinTransaction(
    store: UsageStore,
    cutoff retentionCutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) {
    let providerFilterSignature = enabledProviders
      .map(\.rawValue)
      .sorted()
      .joined(separator: ",")

    if enabledProviders.contains(.codex) {
      let codexRoot = homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
      importOutcomes["codex:file:"] = importTranscriptFiles(
        root: codexRoot,
        prefix: "codex:file:",
        sourceName: "Codex rollout",
        provider: .codex,
        harness: "Codex",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        var state = CodexUsageScanState()
        var records: [UsageSample] = []
        let usageMarker = Data("\"token_count\"".utf8)
        let contextMarker = Data("\"turn_context\"".utf8)
        let metadataMarker = Data("\"session_meta\"".utf8)
        try self.forEachLineData(in: url) { data, lineNumber in
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
      importOutcomes["claude:file:"] = importTranscriptFiles(
        root: claudeRoot,
        prefix: "claude:file:",
        sourceName: "Claude transcript",
        provider: .claude,
        harness: "Claude Code",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        var records: [UsageSample] = []
        let usageMarker = Data("\"usage\"".utf8)
        try self.forEachLineData(in: url) { data, lineNumber in
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
      importOutcomes["pi:file:"] = importHarnessFiles(
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
      importOutcomes["openclaw:file:"] = importHarnessFiles(
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
      importOutcomes["hermes:database"] = importDatabase(
        databaseURL: hermesDatabase,
        sourceID: "hermes:database",
        sourceName: "Hermes usage ledger",
        provider: .unknown,
        harness: "Hermes",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter in
        try HermesUsageDatabase(databaseURL: hermesDatabase)
          .samples(cutoff: indexedAfter, now: now)
          .filter { enabledProviders.contains($0.provider) }
      }
    }

    if enabledProviders.contains(.grok) {
      let grokRoot = homeDirectory.appending(path: ".grok/sessions", directoryHint: .isDirectory)
      importOutcomes["grok:file:"] = importGrok(
        root: grokRoot,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      )
    }

    if enabledProviders.contains(.openCodeGo) {
      let openCodeDatabase = homeDirectory.appending(path: ".local/share/opencode/opencode.db")
      importOutcomes["opencode:database"] = importDatabase(
        databaseURL: openCodeDatabase,
        sourceID: "opencode:database",
        sourceName: "OpenCode history",
        provider: .openCodeGo,
        harness: "OpenCode",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter in
        try OpenCodeUsageDatabase(databaseURL: openCodeDatabase)
          .samples(cutoff: indexedAfter, now: now)
          .filter { $0.provider == .openCodeGo }
      }
    }
  }

  private func importTranscriptFiles(
    root: URL,
    prefix: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date,
    predicate: (URL) -> Bool = { $0.pathExtension == "jsonl" },
    fingerprint: ((URL) throws -> String)? = nil,
    parser: (URL) throws -> [UsageSample]
  ) -> Outcome {
    guard fileManager.fileExists(atPath: root.path) else { return .empty }
    let files = files(root: root, cutoff: cutoff, predicate: predicate)
    var failures = 0
    for file in files {
      do {
        let currentFingerprint: String
        if let fingerprint {
          currentFingerprint = try fingerprint(file) + ":" + providerFilterSignature
        } else {
          currentFingerprint = try fileFingerprint(file) + ":" + providerFilterSignature
        }
        let sourceID = prefix + file.path
        let stored = try store.source(sourceID)
        let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
        guard stored?.fingerprint != currentFingerprint
                || stored?.indexedAfter == nil
                || (stored?.indexedAfter ?? .distantFuture) > cutoff else { continue }
        let samples = try parser(file).filter {
          $0.timestamp >= indexedAfter && $0.timestamp <= now
        }
        try store.replace(
          sourceID: sourceID,
          sourceName: sourceName,
          location: abbreviated(file),
          provider: provider,
          harness: harness,
          fingerprint: currentFingerprint,
          samples: uniqueSourceEvents(samples),
          importedAt: now,
          indexedAfter: indexedAfter,
          transactional: false
        )
      } catch {
        failures += 1
      }
    }
    return Outcome(failures: failures)
  }

  private func importHarnessFiles(
    root: URL,
    prefix: String,
    harness: String,
    enabledProviders: Set<ProviderKind>,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date,
    predicate: (URL) -> Bool = { $0.pathExtension == "jsonl" }
  ) -> Outcome {
    importTranscriptFiles(
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
    ) { url in
      var state = HarnessUsageScanState()
      var records: [UsageSample] = []
      let usageMarker = Data("\"usage\"".utf8)
      let modelMarker = Data("\"model_change\"".utf8)
      let thinkingMarker = Data("\"thinking_level_change\"".utf8)
      let sessionMarker = Data("\"session\"".utf8)
      try self.forEachLineData(in: url) { data, lineNumber in
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
    store: UsageStore,
    cutoff: Date,
    now: Date
  ) -> Outcome {
    importTranscriptFiles(
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
      fingerprint: { try self.grokFingerprint($0) }
    ) { url in
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
      try self.forEachLineData(in: url) { data, lineNumber in
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
    store: UsageStore,
    cutoff: Date,
    now: Date,
    reader: (Date) throws -> [UsageSample]
  ) -> Outcome {
    guard fileManager.fileExists(atPath: databaseURL.path) else { return .empty }
    do {
      let fingerprint = try databaseFingerprint(databaseURL) + ":" + providerFilterSignature
      let stored = try store.source(sourceID)
      let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
      if stored?.fingerprint != fingerprint
          || stored?.indexedAfter == nil
          || (stored?.indexedAfter ?? .distantFuture) > cutoff {
        let samples = try reader(indexedAfter).filter {
          $0.timestamp >= indexedAfter && $0.timestamp <= now
        }
        try store.replace(
          sourceID: sourceID,
          sourceName: sourceName,
          location: abbreviated(databaseURL),
          provider: provider,
          harness: harness,
          fingerprint: fingerprint,
          samples: uniqueSourceEvents(samples),
          importedAt: now,
          indexedAfter: indexedAfter,
          transactional: false
        )
      }
      return Outcome(failures: 0)
    } catch {
      return Outcome(failures: 1)
    }
  }

  private func fileFingerprint(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return [
      Self.parserVersion,
      String(values.fileSize ?? 0),
      String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
    ].joined(separator: ":")
  }

  private func databaseFingerprint(_ url: URL) throws -> String {
    var values = [try fileFingerprint(url)]
    for suffix in ["-wal", "-shm"] {
      let sidecar = URL(fileURLWithPath: url.path + suffix)
      if fileManager.fileExists(atPath: sidecar.path) {
        values.append(try fileFingerprint(sidecar))
      }
    }
    return values.joined(separator: "|")
  }

  private func grokFingerprint(_ updatesURL: URL) throws -> String {
    var values = [try fileFingerprint(updatesURL)]
    let summaryURL = updatesURL.deletingLastPathComponent().appending(path: "summary.json")
    if fileManager.fileExists(atPath: summaryURL.path) {
      values.append(try fileFingerprint(summaryURL))
    }
    return values.joined(separator: "|")
  }

  private func files(
    root: URL,
    cutoff: Date,
    predicate: (URL) -> Bool
  ) -> [URL] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where predicate(url) {
      guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
      result.append(url)
    }
    return result.sorted { $0.path < $1.path }
  }

  private func forEachLineData(
    in url: URL,
    body: (Data.SubSequence, Int) throws -> Void
  ) throws {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var start = 0
      var lineNumber = 0
      while start < rawBuffer.count {
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

  private func uniqueSourceEvents(_ samples: [UsageSample]) -> [UsageSample] {
    var seen: Set<String> = []
    return samples.filter { seen.insert($0.sourceEventID).inserted }
  }

  private func abbreviated(_ url: URL) -> String {
    let home = homeDirectory.path
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }}
