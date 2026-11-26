import Foundation
import WovenLibrary
import WovenProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads the harness histories of this machine's account into the library:
/// at start, then every two minutes. Each history is read on from where the
/// last read stopped, so a pass over unchanged files only looks at their
/// sizes. A pass first reads on the histories that grew, then those never
/// read (or whose place cannot be trusted), newest first, for a bounded
/// time; while some are left the next pass follows at once. So on a new
/// machine the last day shows first, then the week, the month and the rest.
/// The histories are opened for reading only.
actor UsageScanner {
  struct Pass: Sendable, Equatable {
    /// Histories that had something new.
    var read = 0
    /// Responses found, and those not counted before.
    var found = 0
    var added = 0
    /// Synced usage rows written.
    var records = 0
    /// Histories left for the next pass.
    var left = 0
  }

  private let library: Library
  private let home: URL
  private let environment: [String: String]
  private let chunk: Int
  private let slice: Duration
  /// The time gone by, for the slice.
  private let clock: @Sendable () -> Duration
  private var task: Task<Void, Never>?
  /// For tests: called with a history's source as its read begins.
  private let willRead: (@Sendable (String) async -> Void)?
  private let log: @Sendable (String) -> Void
  /// While histories not read yet are read: the next stage to report and
  /// how many have been read since that began. The first pass begins one.
  private var backfill: (stage: Int, read: Int)? = (0, 0)
  /// The history the last pass's share ended in, before its end.
  private var unfinished: String?

  /// `environment` is the server's own, for the homes it names; `chunk` the
  /// most of a history read and saved in one step; `slice` how long one pass
  /// reads before it ends, by `clock`.
  init(library: Library, home: URL, environment: [String: String] = [:], chunk: Int = 64 * 1024 * 1024,
       slice: Duration = .seconds(20), willRead: (@Sendable (String) async -> Void)? = nil,
       clock: (@Sendable () -> Duration)? = nil,
       log: @escaping @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data(("woven-server: " + $0 + "\n").utf8)) }) {
    self.library = library
    self.home = home
    self.environment = environment
    self.chunk = max(chunk, 1)
    self.slice = slice
    let origin = ContinuousClock.now
    self.clock = clock ?? { ContinuousClock.now - origin }
    self.willRead = willRead
    self.log = log
  }

  func start(every interval: Duration = .seconds(120)) {
    task = Task { [weak self] in
      while !Task.isCancelled {
        let left = await self?.scanAndReport() ?? 0
        try? await Task.sleep(for: left > 0 ? .seconds(1) : interval)
      }
    }
  }

  /// Ends the scanning once the step being read is saved: a history's
  /// chunk, or OpenCode's page. A normal stop leaves no read counted as
  /// interrupted.
  func stop() async {
    guard let task else { return }
    task.cancel()
    await task.value
    self.task = nil
  }

  private func scanAndReport() async -> Int {
    let started = Date()
    let pass = await scan()
    guard pass.read > 0 || pass.records > 0 else { return pass.left }
    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
    log("usage read \(pass.read) histories, \(pass.added) new of \(pass.found) responses, \(pass.records) records, "
             + "in \(seconds)s" + (pass.left > 0 ? ", \(pass.left) left" : ""))
    return pass.left
  }

  // MARK: Passes

  /// A history to read in this pass.
  private struct Work {
    let history: History
    let size: Int64
    let modified: Int64
    /// It has a trusted place and grew since: only its tail is new.
    let tail: Bool
  }

  private enum History {
    case file(HistoryFile)
    case openCode(path: String, source: String)

    var source: String {
      switch self {
      case .file(let file): file.source
      case .openCode(_, let source): source
      }
    }
  }

  /// The ages a backlog is reported at, newest first.
  private static let stages: [(seconds: Double, name: String)] = [
    (86_400, "24 hours"), (7 * 86_400, "7 days"), (30 * 86_400, "30 days"), (90 * 86_400, "90 days"),
  ]

  /// A history passed over because it could not be read is tried again
  /// after this long even if it has not changed.
  static let passedOverRetry: Int64 = 86_400_000

  /// One pass. First the tails of histories read before that grew, for at
  /// most half the slice when others wait; then the histories not read yet
  /// (or not to their end, or whose place cannot be trusted), newest first,
  /// for the rest of it. Whatever is left comes first again next pass.
  @discardableResult
  func scan() async -> Pass {
    var pass = Pass()
    guard let sources = try? await library.usageSources() else { return pass }
    let now = Date()
    var tails: [Work] = [], backlog: [Work] = []
    for history in histories() {
      let size: Int64, modified: Int64
      switch history {
      case .file(let file):
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path) else { continue }
        (size, modified) = Self.stat(attributes)
      case .openCode(let path, _):
        guard FileManager.default.fileExists(atPath: path) else { continue }
        var total: Int64 = 0, newest: Int64 = 0
        for file in [path, path + "-wal"] {
          guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else { continue }
          let (fileSize, fileModified) = Self.stat(attributes)
          total += fileSize
          newest = max(newest, fileModified)
        }
        (size, modified) = (total, newest)
      }
      let known = sources[history.source]
      let trusted = known.map { !$0.boundary.isEmpty } ?? false
      if let known, trusted, known.size == size, known.modified == modified,
         known.passedOver == 0 || Int64(now.timeIntervalSince1970 * 1000) - known.passedOver < Self.passedOverRetry { continue }
      // Read to its end before (its change time recorded then), and readable.
      let tail = trusted && known?.passedOver == 0 && known?.modified != 0
      let work = Work(history: history, size: size, modified: modified, tail: tail)
      if tail { tails.append(work) } else { backlog.append(work) }
    }
    // Newest first: a history unchanged since a time holds nothing newer than it.
    let order = { (a: Work, b: Work) in (a.modified, a.history.source) > (b.modified, b.history.source) }
    tails.sort(by: order)
    backlog.sort(by: order)
    // After a pass whose share one history used up without reaching its
    // end, the next begins with the history after it.
    if let unfinished, let index = backlog.firstIndex(where: { $0.history.source == unfinished }) {
      backlog = Array(backlog[(index + 1)...] + backlog[...index])
    }
    if backfill == nil, backlog.contains(where: { Double($0.modified) / 1000 < now.timeIntervalSince1970 - 86_400 }) {
      backfill = (0, 0)
    }
    let begin = clock()
    let end = begin + slice
    let tailsEnd = backlog.isEmpty ? end : begin + slice / 2

    if await run(&tails, until: tailsEnd, backlog: false, sources: sources, now: now, into: &pass),
       await run(&backlog, until: end, backlog: true, sources: sources, now: now, into: &pass), backlog.isEmpty, clock() < end {
      _ = await run(&tails, until: end, backlog: false, sources: sources, now: now, into: &pass)
    }
    pass.left = tails.count + backlog.count
    if backlog.isEmpty, !Task.isCancelled {
      report(before: nil, now: now)
      backfill = nil
    }
    return pass
  }

  /// Reads the histories of `list` from the front until `deadline`, the
  /// first one whatever the time, removing those read to their end.
  /// Returns false when a stop came.
  private func run(_ list: inout [Work], until deadline: Duration, backlog: Bool, sources: [String: UsageSource], now: Date,
                   into pass: inout Pass) async -> Bool {
    var first = true
    if backlog { unfinished = nil }
    while let item = list.first {
      if Task.isCancelled { return false }
      if !first && clock() >= deadline { return true }
      first = false
      if backlog { report(before: Double(item.modified) / 1000, now: now) }
      let finished = (try? await read(item, known: sources[item.history.source], deadline: deadline, into: &pass)) ?? true
      guard finished else {
        if backlog { unfinished = item.history.source }
        return !Task.isCancelled
      }
      if backlog, backfill != nil { backfill?.read += 1 }
      list.removeFirst()
    }
    return true
  }

  /// Reports each backfill stage that is complete once the work reaches a
  /// history last changed at `modified` (nil: the work is done). Each is
  /// reported once.
  private func report(before modified: Double?, now: Date) {
    while let current = backfill, current.stage <= Self.stages.count {
      if current.stage < Self.stages.count {
        guard modified.map({ $0 < now.timeIntervalSince1970 - Self.stages[current.stage].seconds }) ?? true else { return }
        log("usage history read back \(Self.stages[current.stage].name) (\(current.read) histories)")
      } else {
        guard modified == nil else { return }
        log("usage history read in full (\(current.read) histories)")
      }
      backfill = (current.stage + 1, current.read)
    }
  }

  private static func stat(_ attributes: [FileAttributeKey: Any]) -> (Int64, Int64) {
    ((attributes[.size] as? NSNumber)?.int64Value ?? 0,
     Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000))
  }

  /// Reads one history; returns false when the slice ran out part-way and
  /// the place reached was saved.
  private func read(_ item: Work, known: UsageSource?, deadline: Duration, into pass: inout Pass) async throws -> Bool {
    switch item.history {
    case .file(let file):
      try await read(file, size: item.size, modified: item.modified, known: known, deadline: deadline, into: &pass)
    case .openCode(let path, let source):
      try await readOpenCode(path, source: source, size: item.size, modified: item.modified, known: known,
                             deadline: deadline, into: &pass)
    }
  }

  // MARK: Where histories are

  private struct HistoryFile {
    let url: URL
    /// The read position's key: a digest, so no path enters the library.
    let source: String
    let kind: HistoryKind
    let compressed: Bool
  }

  /// Every history of this account: each harness's own home, and the homes
  /// the server's environment names instead, and Claude Code transcripts
  /// the Claude app keeps for its own sessions.
  private func histories() -> [History] {
    var histories: [History] = []
    func extra(_ variable: String, _ path: String, default standard: URL) -> URL? {
      guard let value = environment[variable], !value.isEmpty else { return nil }
      let url = URL(fileURLWithPath: value, isDirectory: true).appendingPathComponent(path)
      return url.standardizedFileURL.path == standard.standardizedFileURL.path ? nil : url
    }

    let codexHome = home.appendingPathComponent(".codex")
    for (root, key) in [(codexHome, "")] + (extra("CODEX_HOME", "", default: codexHome).map { [($0, $0.path)] } ?? []) {
      histories += codex(root, key: key)
    }

    let projects = home.appendingPathComponent(".claude/projects")
    var claudeRoots = [(projects, "")]
    if let configured = extra("CLAUDE_CONFIG_DIR", "projects", default: projects) { claudeRoots.append((configured, configured.path)) }
    let xdgConfig = home.appendingPathComponent(".config/claude/projects")
    if FileManager.default.fileExists(atPath: xdgConfig.path) { claudeRoots.append((xdgConfig, xdgConfig.path)) }
    #if os(macOS)
    let desktop = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    claudeRoots += Self.nestedProjects(under: desktop).map { ($0, $0.path) }
    #endif
    for (root, key) in claudeRoots {
      for url in Self.files(under: root) where url.pathExtension == "jsonl" {
        let agent = url.deletingLastPathComponent().lastPathComponent == "subagents"
        histories.append(.file(HistoryFile(url: url, source: Self.source("claude", key + Self.relative(url, to: root)),
                                           kind: .claude(session: agent ? nil : url.deletingPathExtension().lastPathComponent),
                                           compressed: false)))
      }
    }

    for url in Self.files(under: home.appendingPathComponent(".grok/sessions")) where url.lastPathComponent == "updates.jsonl" {
      let folder = url.deletingLastPathComponent()
      histories.append(.file(HistoryFile(url: url, source: Self.source("grok", folder.lastPathComponent),
                                         kind: .grok(session: folder.lastPathComponent,
                                                     summary: folder.appendingPathComponent("summary.json")),
                                         compressed: false)))
    }

    let pi = home.appendingPathComponent(".pi/agent/sessions")
    for url in Self.files(under: pi) where url.pathExtension == "jsonl" {
      histories.append(.file(HistoryFile(url: url, source: Self.source("pi", Self.relative(url, to: pi)), kind: .pi,
                                         compressed: false)))
    }

    let openCode = home.appendingPathComponent(".local/share/opencode/opencode.db")
    histories.append(.openCode(path: openCode.path, source: Self.openCodeSource))
    if let configured = extra("XDG_DATA_HOME", "opencode/opencode.db", default: openCode) {
      histories.append(.openCode(path: configured.path, source: Self.source("opencode", configured.path)))
    }
    return histories
  }

  /// Codex moves a thread it archives to `archived_sessions` and later
  /// compresses it; by its name it stays one source, read on from where it
  /// was. `key` tells one Codex home's sources from another's.
  private func codex(_ root: URL, key: String) -> [History] {
    var codex: [String: HistoryFile] = [:]
    for folder in ["sessions", "archived_sessions"] {
      for url in Self.files(under: root.appendingPathComponent(folder)) {
        let name = url.lastPathComponent
        let compressed = name.hasSuffix(".jsonl.zst")
        guard name.hasPrefix("rollout-"), compressed || name.hasSuffix(".jsonl") else { continue }
        let plain = compressed ? String(name.dropLast(4)) : name
        if codex[plain].map({ !$0.compressed }) == true { continue }
        codex[plain] = HistoryFile(url: url, source: Self.source("codex", key.isEmpty ? plain : key + "\n" + plain), kind: .codex,
                                   compressed: compressed)
      }
    }
    return codex.values.sorted { $0.url.path < $1.url.path }.map(History.file)
  }

  /// The `.claude/projects` folders anywhere below `root`.
  private static func nestedProjects(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    var found: [URL] = []
    for case let url as URL in enumerator {
      guard url.lastPathComponent == "projects", url.deletingLastPathComponent().lastPathComponent == ".claude" else { continue }
      found.append(url)
      enumerator.skipDescendants()
    }
    return found.sorted { $0.path < $1.path }
  }

  // MARK: Reading a file

  /// A history open at this many unclean ends of the process in a row is
  /// taken to be what ended it. One could be a kill or a power loss that
  /// happened while it was open; a history that traps the reader does so
  /// every time, so a second confirms it at the cost of one more crash.
  static let interruptedReadsBeforePassingOver: Int64 = 2

  /// Before a history is read, the attempt is counted in its row, and every
  /// end of the read (finished, failed, or stopped) clears the count. A count
  /// still there at the next read means the process ended during the last
  /// one: the history is read again, unless that has happened
  /// `interruptedReadsBeforePassingOver` times, when it is passed over like
  /// one that failed. Returns the counted row to read with, or nil.
  private func begin(_ known: UsageSource?, id: String, size: Int64, modified: Int64) async throws -> UsageSource? {
    var source = known ?? UsageSource(id: id)
    guard source.interrupted < Self.interruptedReadsBeforePassingOver else {
      try await passOver(source, size: size, modified: modified)
      return nil
    }
    source.interrupted += 1
    try await library.saveUsage([], source: source)
    await willRead?(id)
    return source
  }

  /// Passed over until it changes, or a day has gone by: its size and change
  /// time recorded, its read position where it was. One with no trusted
  /// position is placed at its start.
  private func passOver(_ source: UsageSource, size: Int64, modified: Int64) async throws {
    var source = source.boundary.isEmpty ? UsageSource(id: source.id, boundary: Self.start) : source
    source.size = size
    source.modified = modified
    source.interrupted = 0
    source.passedOver = Int64(Date().timeIntervalSince1970 * 1000)
    try await library.saveUsage([], source: source)
  }

  /// Reads what is new in one file, a chunk at a time, saving each with the
  /// place reached. A file that cannot be read (it fails to decompress, or
  /// reading it fails), or whose reading ended the process more than once,
  /// is passed over; what was saved before the failure stays. A line that
  /// is not what its harness writes is skipped on its own. Returns false
  /// when the slice ran out part-way.
  private func read(_ file: HistoryFile, size: Int64, modified: Int64, known: UsageSource?, deadline: Duration,
                    into pass: inout Pass) async throws -> Bool {
    // A file with no complete first line yet is not read yet.
    guard try file.compressed || Self.identity(of: file.url) != nil else { return true }
    guard let counted = try await begin(known, id: file.source, size: size, modified: modified) else { return true }
    var saved = counted
    do {
      let finished = try await (file.compressed
        ? readCompressed(file, size: size, modified: modified, known: known, counted: counted, deadline: deadline,
                         saved: &saved, into: &pass)
        : readPlain(file, size: size, modified: modified, known: known, counted: counted, deadline: deadline,
                    saved: &saved, into: &pass))
      pass.read += 1
      return finished
    } catch {
      try await passOver(saved, size: size, modified: modified)
      return true
    }
  }

  private func readPlain(_ file: HistoryFile, size: Int64, modified: Int64, known: UsageSource?, counted: UsageSource,
                         deadline: Duration, saved: inout UsageSource, into pass: inout Pass) async throws -> Bool {
    guard let identity = try Self.identity(of: file.url) else { return true }
    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    var start: Int64 = 0
    var state = ReaderState()
    if let known, !known.boundary.isEmpty, known.identity == identity, known.offset <= size,
       let resumed = try? JSONDecoder().decode(ReaderState.self, from: Data(known.state.utf8)),
       try Self.boundary(handle, at: known.offset) == known.boundary {
      start = known.offset
      state = resumed
    }
    model(file, &state)
    var lines = LineReader(offset: start, limit: chunk, tail: try Self.bytes(handle, before: start))
    while true {
      try handle.seek(toOffset: UInt64(lines.offset))
      let from = lines.offset
      var entries: [UsageEntry] = []
      var end = false
      while lines.offset - from < Int64(chunk) {
        guard let data = try handle.read(upToCount: min(chunk, 1 << 20)), !data.isEmpty else {
          end = true
          break
        }
        data.withUnsafeBytes { bytes in
          lines.feed(bytes) { line in entries += HistoryReader.entries(line, kind: file.kind, state: &state) }
        }
      }
      // A part-line read past the place is read again from there.
      lines.rewind()
      let stopped = !end && (Task.isCancelled || clock() >= deadline)
      let next = UsageSource(id: file.source, offset: lines.offset, size: end ? size : 0, modified: end ? modified : 0,
                             identity: identity, boundary: lines.boundary, state: try Self.encode(state),
                             interrupted: end || stopped ? 0 : counted.interrupted)
      let result = try await save(entries, next)
      // The place moves on only once it is saved.
      saved = next
      pass.found += entries.count
      pass.added += result.added
      pass.records += result.records
      if end { return true }
      if stopped { return false }
    }
  }

  /// A compressed rollout is decoded from its start each time, as a stream
  /// read through the file a piece at a time; what lies before the place
  /// reached is checked, not read again. A stream that does not match the
  /// place is read from its start. A stop is taken between blocks. If a
  /// block cannot be decoded, the whole lines before it are saved first.
  private func readCompressed(_ file: HistoryFile, size: Int64, modified: Int64, known: UsageSource?, counted: UsageSource,
                              deadline: Duration, saved: inout UsageSource, into pass: inout Pass) async throws -> Bool {
    var resume = known.flatMap { known -> (UsageSource, ReaderState)? in
      guard !known.boundary.isEmpty, !known.identity.isEmpty,
            let state = try? JSONDecoder().decode(ReaderState.self, from: Data(known.state.utf8)) else { return nil }
      return (known, state)
    }
    while true {
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }
      var decoder = Zstd.Decoder { count in try handle.read(upToCount: count) ?? Data() }
      var state = resume?.1 ?? ReaderState()
      model(file, &state)
      var lines = LineReader(offset: 0, limit: chunk, skipUntil: resume?.0.offset ?? 0)
      var head = IdentityReader()
      var entries: [UsageEntry] = []
      var savedAt = resume?.0.offset ?? 0
      var mismatch: Bool {
        guard let resume else { return false }
        return lines.missed || (lines.reached.map { $0 != resume.0.boundary } ?? false)
          || (head.identity.map { $0 != resume.0.identity } ?? false)
      }
      /// The place reached, to save with what was read up to it.
      func place(end: Bool, stopped: Bool) throws -> UsageSource {
        UsageSource(id: file.source, offset: lines.offset, size: end ? size : 0, modified: end ? modified : 0,
                    identity: head.identity ?? "", boundary: lines.boundary, state: try Self.encode(state),
                    interrupted: end || stopped ? 0 : counted.interrupted)
      }
      var blocks = 0
      while true {
        // The scanner gives way now and then, so a stop can reach it.
        blocks += 1
        if blocks % 64 == 0 { await Task.yield() }
        if Task.isCancelled {
          // Ends the read cleanly; the next one decodes from the start again.
          if lines.reached != nil, !mismatch {
            let next = try place(end: false, stopped: true)
            try await commit(entries, next, into: &pass)
            saved = next
          } else {
            var unchanged = saved
            unchanged.interrupted = 0
            try await library.saveUsage([], source: unchanged)
            saved = unchanged
          }
          return false
        }
        let block: [UInt8]?
        do {
          block = try decoder.next()
        } catch {
          if lines.reached != nil, !mismatch, lines.offset > savedAt {
            let next = try place(end: false, stopped: true)
            try await commit(entries, next, into: &pass)
            saved = next
          }
          throw error
        }
        guard let block else { break }
        block.withUnsafeBytes { bytes in
          head.feed(bytes)
          lines.feed(bytes) { line in entries += HistoryReader.entries(line, kind: file.kind, state: &state) }
        }
        if mismatch { break }
        if lines.reached != nil, lines.offset - savedAt >= Int64(chunk) {
          let stopped = clock() >= deadline
          let next = try place(end: false, stopped: stopped)
          try await commit(entries, next, into: &pass)
          saved = next
          entries = []
          savedAt = lines.offset
          if stopped { return false }
        }
      }
      if !mismatch {
        lines.finish { line in entries += HistoryReader.entries(line, kind: file.kind, state: &state) }
        head.finish()
      }
      if resume != nil, mismatch || lines.reached == nil {
        // Not the stream the place was in: read from the start.
        resume = nil
        continue
      }
      let next = try place(end: true, stopped: false)
      try await commit(entries, next, into: &pass)
      saved = next
      return true
    }
  }

  /// Saves what one step of a read found with the place it reached.
  private func commit(_ entries: [UsageEntry], _ next: UsageSource, into pass: inout Pass) async throws {
    let result = try await save(entries, next)
    pass.found += entries.count
    pass.added += result.added
    pass.records += result.records
  }

  /// Saves usage with a source's place.
  private func save(_ entries: [UsageEntry], _ source: UsageSource) async throws -> UsageSaved {
    if !entries.isEmpty, failingSaves > 0 {
      failingSaves -= 1
      throw SaveFailure()
    }
    return try await library.saveUsage(entries, source: source)
  }

  /// For tests: the next saves of responses fail, as on a full disk.
  private var failingSaves = 0
  private struct SaveFailure: Error {}

  func failNextSaves(_ count: Int) { failingSaves = count }

  /// Grok Build names the session's model in its summary.
  private func model(_ file: HistoryFile, _ state: inout ReaderState) {
    if case .grok(_, let summary) = file.kind, state.model == nil,
       let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: summary))) as? [String: Any] {
      state.model = object["current_model_id"] as? String
    }
  }

  private static func encode(_ state: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
  }

  /// A plain file is the same history while its first line is: copied,
  /// restored or rewritten whole, it is read on from where it stopped. Nil
  /// while it has no complete first line within `IdentityReader.limit`.
  private static func identity(of url: URL) throws -> String? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var reader = IdentityReader()
    (try handle.read(upToCount: IdentityReader.limit) ?? Data()).withUnsafeBytes { reader.feed($0) }
    return reader.identity
  }

  /// What a position's boundary is checked against: the bytes before it.
  private static let boundaryLength = 256
  /// The boundary of the start of a file.
  static let start = "start"

  private static func boundary(_ bytes: some Collection<UInt8>, at offset: Int64) -> String {
    offset == 0 ? start : "tail:" + Library.digest(of: Data(bytes))
  }

  private static func bytes(_ handle: FileHandle, before offset: Int64) throws -> [UInt8] {
    guard offset > 0 else { return [] }
    let from = max(0, offset - Int64(boundaryLength))
    try handle.seek(toOffset: UInt64(from))
    return [UInt8](try handle.read(upToCount: Int(offset - from)) ?? Data())
  }

  private static func boundary(_ handle: FileHandle, at offset: Int64) throws -> String {
    boundary(try bytes(handle, before: offset), at: offset)
  }

  /// Splits bytes into lines, keeping the place after the last whole line
  /// and the bytes just before it. A line longer than `limit` is skipped.
  /// Lines that end at or before `skipUntil` were read before: they are not
  /// handed out, and the place must be where one of them ends.
  private struct LineReader {
    private(set) var offset: Int64
    let limit: Int
    let skipUntil: Int64
    /// The place `skipUntil` was found to be a line's end, with the boundary there.
    private(set) var reached: String?
    /// A line ran past `skipUntil`: it is not a place this stream has.
    private(set) var missed = false
    private var partial: [UInt8] = []
    /// The line being fed is too long: its bytes are counted, not kept.
    private var skipping = false
    /// The bytes of the line being fed so far.
    private var length = 0
    /// The last bytes before `offset`, and the last bytes fed.
    private var tail: [UInt8]
    private var recent: [UInt8]

    init(offset: Int64, limit: Int, skipUntil: Int64 = 0, tail: [UInt8] = []) {
      self.offset = offset
      self.limit = limit
      self.skipUntil = skipUntil
      self.tail = tail
      recent = tail
      if skipUntil <= offset { reached = UsageScanner.boundary(tail, at: offset) }
    }

    var boundary: String { UsageScanner.boundary(tail, at: offset) }

    mutating func feed(_ bytes: UnsafeRawBufferPointer, _ line: (UnsafeRawBufferPointer) -> Void) {
      guard let base = bytes.baseAddress else { return }
      var start = 0
      while start < bytes.count {
        guard let found = memchr(base + start, 0x0A, bytes.count - start) else {
          length += bytes.count - start
          if !skipping {
            partial.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start...]))
            if partial.count > limit {
              partial.removeAll()
              skipping = true
            }
          }
          break
        }
        let end = base.distance(to: UnsafeRawPointer(found))
        let piece = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
        // Every byte of the line, kept or not, and its newline.
        let whole = length + piece.count
        offset += Int64(whole + 1)
        tail = end + 1 >= UsageScanner.boundaryLength
          ? Array(bytes[(end + 1 - UsageScanner.boundaryLength)...end])
          : Array((recent + bytes[...end]).suffix(UsageScanner.boundaryLength))
        if offset <= skipUntil {
          if offset == skipUntil { reached = boundary }
        } else if reached == nil {
          missed = true
        } else if skipping || whole > limit {
          // Too long for any history to mean: passed over whole.
        } else if partial.isEmpty {
          line(piece)
        } else {
          partial.append(contentsOf: piece)
          partial.withUnsafeBytes { line($0) }
        }
        partial.removeAll(keepingCapacity: partial.count < 1 << 20)
        skipping = false
        length = 0
        start = end + 1
      }
      recent = bytes.count >= UsageScanner.boundaryLength
        ? Array(bytes.suffix(UsageScanner.boundaryLength))
        : Array((recent + bytes).suffix(UsageScanner.boundaryLength))
    }

    /// The end of a finished stream: a last line without a newline is whole.
    mutating func finish(_ line: (UnsafeRawBufferPointer) -> Void) {
      guard length > 0 else { return }
      offset += Int64(length)
      tail = recent
      let last = partial
      let kept = !skipping
      partial.removeAll()
      skipping = false
      length = 0
      if offset <= skipUntil {
        if offset == skipUntil { reached = boundary }
      } else if reached == nil {
        missed = true
      } else if kept {
        last.withUnsafeBytes { line($0) }
      }
    }

    /// Forgets what was fed past the place, to be fed again from there.
    mutating func rewind() {
      partial.removeAll()
      skipping = false
      length = 0
      recent = tail
    }
  }

  /// A history's identity: a digest of its first line, or of its first
  /// `limit` bytes when that line is longer.
  private struct IdentityReader {
    static let limit = 64 * 1024
    private var head: [UInt8] = []
    private(set) var identity: String?

    mutating func feed(_ bytes: UnsafeRawBufferPointer) {
      guard identity == nil else { return }
      let room = Self.limit - head.count
      let piece = bytes.prefix(room)
      if let newline = piece.firstIndex(of: 0x0A) {
        head.append(contentsOf: piece[..<newline])
        identity = "head:" + Library.digest(of: Data(head))
      } else {
        head.append(contentsOf: piece)
        if head.count >= Self.limit { identity = "head:" + Library.digest(of: Data(head)) }
      }
    }

    /// The end of a finished stream: what there is is its first line.
    mutating func finish() {
      if identity == nil { identity = "head:" + Library.digest(of: Data(head)) }
    }
  }

  // MARK: OpenCode

  private static let openCodeSource = "opencode"

  /// OpenCode keeps its history in one database, read on from the last
  /// message seen, which must still be there; each new read takes in the
  /// hour before it again. Its size and change time
  /// include the write-ahead log. Its reads are counted as a file's are;
  /// each page saved moves the place on and keeps the count until the
  /// last, so an interrupted read goes on from that page.
  private func readOpenCode(_ path: String, source: String, size: Int64, modified: Int64, known: UsageSource?,
                            deadline: Duration, into pass: inout Pass) async throws -> Bool {
    guard let counted = try await begin(known, id: source, size: size, modified: modified) else { return true }
    var saved = counted
    do {
      let database = try ReadOnlyDatabase(path: path)
      var cursor: (time: Int64, id: String) = (0, "")
      var overlap: OpenCodeOverlap?
      // The size and change time seen as this read of the database began,
      // stored when it ends: a change during the read then leaves them
      // different from the file's, and the next pass reads again.
      var stamp = (size: size, modified: modified)
      if let known, known.boundary == Self.openCodeBoundary(known.identity),
         try known.identity.isEmpty || HistoryReader.openCodeHas(database, message: known.identity) {
        cursor = (known.offset, known.identity)
        if let pending = try? JSONDecoder().decode(OpenCodeRead.self, from: Data(known.state.utf8)) {
          overlap = pending.overlap
          stamp = (pending.size, pending.modified)
        } else if known.modified != 0, !known.identity.isEmpty {
          // A new read also takes in the hour before the place again, so a
          // message whose update is stamped before the place was saved is
          // not missed. That hour is read with a place of its own; the
          // place read on from only moves forward.
          overlap = OpenCodeOverlap(afterTime: max(0, cursor.time - Self.openCodeOverlap), afterID: "",
                                    throughTime: cursor.time, throughID: cursor.id)
        }
      }
      let limit = 500
      while true {
        if var again = overlap {
          let page = try HistoryReader.openCode(database, after: (again.afterTime, again.afterID),
                                                through: (again.throughTime, again.throughID), limit: limit)
          let done = page.rows < limit || page.cursor == (again.afterTime, again.afterID)
          (again.afterTime, again.afterID) = page.cursor
          let stopped = !done && (Task.isCancelled || clock() >= deadline)
          let next = UsageSource(id: source, offset: cursor.time, identity: cursor.id, boundary: Self.openCodeBoundary(cursor.id),
                                 state: try Self.encode(OpenCodeRead(size: stamp.size, modified: stamp.modified,
                                                                     overlap: done ? nil : again)),
                                 interrupted: stopped ? 0 : counted.interrupted)
          let result = try await save(page.entries, next)
          saved = next
          overlap = done ? nil : again
          pass.found += page.entries.count
          pass.added += result.added
          pass.records += result.records
          if stopped {
            pass.read += 1
            return false
          }
          continue
        }
        let page = try HistoryReader.openCode(database, after: cursor, limit: limit)
        let last = page.rows < limit || page.cursor == cursor
        // A stop or the end of the slice ends the read here, to go on at the next pass.
        let stopped = !last && (Task.isCancelled || clock() >= deadline)
        let next = UsageSource(id: source, offset: page.cursor.time, size: last ? stamp.size : 0,
                               modified: last ? stamp.modified : 0, identity: page.cursor.id,
                               boundary: Self.openCodeBoundary(page.cursor.id),
                               state: last ? "" : try Self.encode(OpenCodeRead(size: stamp.size, modified: stamp.modified)),
                               interrupted: last || stopped ? 0 : counted.interrupted)
        let result = try await save(page.entries, next)
        saved = next
        cursor = page.cursor
        pass.found += page.entries.count
        pass.added += result.added
        pass.records += result.records
        if last || stopped {
          pass.read += 1
          return last
        }
      }
    } catch {
      // Locked past the wait, corrupt or not OpenCode's: tried again once it changes.
      try await passOver(saved, size: size, modified: modified)
      return true
    }
  }

  static let openCodeOverlap: Int64 = 3_600_000

  /// A read of OpenCode's database that went on over several passes: the
  /// size and change time as it began, and the part still to read again.
  private struct OpenCodeRead: Codable {
    var size: Int64
    var modified: Int64
    var overlap: OpenCodeOverlap?
  }

  /// The part of OpenCode's database read again before reading on: the
  /// messages after one place up to and with another.
  private struct OpenCodeOverlap: Codable {
    var afterTime: Int64
    var afterID: String
    var throughTime: Int64
    var throughID: String
  }

  /// The boundary of OpenCode's place: the message it is after.
  private static func openCodeBoundary(_ message: String) -> String {
    message.isEmpty ? start : "message:" + Library.digest(of: Data(message.utf8))
  }

  // MARK: Helpers

  static func source(_ harness: String, _ key: String) -> String {
    harness + ":" + Library.digest(of: Data((harness + "\n" + key).utf8)).prefix(32)
  }

  private static func relative(_ url: URL, to root: URL) -> String {
    let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }

  /// The files below a root, leaving out dot-named files and folders. A
  /// history macOS flags hidden is still read: the flag is a Finder setting
  /// a copy can carry, not a sign the file is not a history.
  private static func files(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator {
      if url.lastPathComponent.hasPrefix(".") {
        enumerator.skipDescendants()
        continue
      }
      if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(url) }
    }
    return files
  }
}
