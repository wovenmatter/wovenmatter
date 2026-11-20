import Foundation
import WovenLibrary
import WovenProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension RuntimeKind {
  /// The harness keeps its own history, and its usage is counted only from
  /// there, inside Woven Matter or not. A turn Woven Matter runs with it
  /// writes no usage record of its own.
  var usageFromHistory: Bool { [.codex, .claudeCode, .grokBuild, .openCode, .piCLI].contains(self) }
}

/// Reads the harness histories of this machine's account into the library:
/// at start, then every two minutes. Each file is read on from where the last
/// read stopped, so a pass over unchanged files only looks at their sizes.
/// The histories are opened for reading only.
actor UsageScanner {
  struct Pass: Sendable, Equatable {
    /// Files and databases that had something new.
    var read = 0
    /// Responses found, and those not counted before.
    var found = 0
    var added = 0
    /// Synced records written for hours that ended.
    var records = 0
  }

  private let library: Library
  private let home: URL
  private var task: Task<Void, Never>?

  init(library: Library, home: URL) {
    self.library = library
    self.home = home
  }

  func start(every interval: Duration = .seconds(120)) {
    task = Task { [weak self] in
      while !Task.isCancelled {
        await self?.scanAndReport()
        try? await Task.sleep(for: interval)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func scanAndReport() async {
    let started = Date()
    let pass = await scan()
    guard pass.read > 0 || pass.records > 0 else { return }
    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
    FileHandle.standardOutput.write(Data(("woven-server: usage read \(pass.read) histories, \(pass.added) new of \(pass.found) "
                                          + "responses, \(pass.records) records, in \(seconds)s\n").utf8))
  }

  /// One pass over every history, then the hours that ended move to synced records.
  @discardableResult
  func scan(now: Date = Date()) async -> Pass {
    var pass = Pass()
    guard let sources = try? await library.usageSources() else { return pass }
    for file in historyFiles() {
      if Task.isCancelled { return pass }
      try? await read(file, known: sources[file.source], into: &pass)
    }
    try? await readOpenCode(known: sources[Self.openCodeSource], into: &pass)
    pass.records = (try? await library.flushUsage(now: now)) ?? 0
    return pass
  }

  // MARK: Files

  private struct HistoryFile {
    let url: URL
    /// The read position's key: a digest, so no path enters the library.
    let source: String
    let kind: HistoryKind
    let compressed: Bool
  }

  private func historyFiles() -> [HistoryFile] {
    var files: [HistoryFile] = []
    // Codex moves a thread it archives to `archived_sessions` and later
    // compresses it; by its name it stays one source, read on from where it was.
    var codex: [String: HistoryFile] = [:]
    for root in [".codex/sessions", ".codex/archived_sessions"] {
      for url in Self.files(under: home.appendingPathComponent(root)) {
        let name = url.lastPathComponent
        let compressed = name.hasSuffix(".jsonl.zst")
        guard name.hasPrefix("rollout-"), compressed || name.hasSuffix(".jsonl") else { continue }
        let key = compressed ? String(name.dropLast(4)) : name
        if codex[key].map({ !$0.compressed }) == true { continue }
        codex[key] = HistoryFile(url: url, source: Self.source("codex", key), kind: .codex, compressed: compressed)
      }
    }
    files += codex.values.sorted { $0.url.path < $1.url.path }

    let projects = home.appendingPathComponent(".claude/projects")
    for url in Self.files(under: projects) where url.pathExtension == "jsonl" {
      let agent = url.deletingLastPathComponent().lastPathComponent == "subagents"
      files.append(HistoryFile(url: url, source: Self.source("claude", Self.relative(url, to: projects)),
                               kind: .claude(session: agent ? nil : url.deletingPathExtension().lastPathComponent),
                               compressed: false))
    }

    for url in Self.files(under: home.appendingPathComponent(".grok/sessions")) where url.lastPathComponent == "updates.jsonl" {
      let folder = url.deletingLastPathComponent()
      files.append(HistoryFile(url: url, source: Self.source("grok", folder.lastPathComponent),
                               kind: .grok(session: folder.lastPathComponent, summary: folder.appendingPathComponent("summary.json")),
                               compressed: false))
    }

    let pi = home.appendingPathComponent(".pi/agent/sessions")
    for url in Self.files(under: pi) where url.pathExtension == "jsonl" {
      files.append(HistoryFile(url: url, source: Self.source("pi", Self.relative(url, to: pi)), kind: .pi, compressed: false))
    }
    return files
  }

  /// Reads what is new in one file. A file that cannot be read (it fails to
  /// decompress, or reading it fails) is passed over with its size and
  /// change time recorded, so it is tried again only once it changes; its
  /// read position stays where it was. A line that is not what its harness
  /// writes is skipped on its own.
  private func read(_ file: HistoryFile, known: UsageSource?, into pass: inout Pass) async throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modified = Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
    if let known, known.size == size, known.modified == modified { return }
    do {
      try await read(file, known: known, size: size, modified: modified, into: &pass)
    } catch {
      try await library.saveUsage([], source: UsageSource(id: file.source, offset: known?.offset ?? 0, size: size, modified: modified,
                                                          identity: known?.identity ?? "", state: known?.state ?? ""))
    }
  }

  /// A plain file is the same history while its first line is: copied,
  /// restored or rewritten whole, it is read on from where it stopped.
  private static func identity(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let head = try handle.read(upToCount: 4096) ?? Data()
    guard let newline = head.firstIndex(of: 0x0A) else { return "" }
    return "head:" + Library.digest(of: head[head.startIndex..<newline])
  }

  private func read(_ file: HistoryFile, known: UsageSource?, size: Int64, modified: Int64, into pass: inout Pass) async throws {
    let identity = file.compressed ? "zst" : try Self.identity(of: file.url)
    var state = known.flatMap { try? JSONDecoder().decode(ReaderState.self, from: Data($0.state.utf8)) } ?? ReaderState()
    var start = known?.offset ?? 0
    let data: Data
    if file.compressed {
      // Read whole; it is the file Codex wrote before, so reading goes on where it stopped.
      guard size <= Zstd.maximumOutput else { throw Zstd.Failure("file too large") }
      data = try Zstd.decompress(try Data(contentsOf: file.url))
      if start > data.count { start = 0 }
    } else {
      if identity.isEmpty || known?.identity != identity || size < start { start = 0 }
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(start))
      data = try handle.read(upToCount: Self.chunk) ?? Data()
    }
    if start == 0 { state = ReaderState() }
    if case .grok(_, let summary) = file.kind, state.model == nil,
       let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: summary))) as? [String: Any] {
      state.model = object["current_model_id"] as? String
    }

    let compressedStart = file.compressed ? Int(start) : 0
    var entries: [UsageEntry] = []
    var consumed = compressedStart
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var lineStart = compressedStart
      while lineStart < bytes.count {
        let rest = bytes.count - lineStart
        let end: Int
        if let newline = memchr(base + lineStart, 0x0A, rest) {
          end = base.distance(to: UnsafeRawPointer(newline))
        } else if file.compressed || (lineStart == 0 && bytes.count == Self.chunk) {
          // The end of a finished file, or a line longer than any history writes, skipped.
          end = bytes.count
        } else {
          break
        }
        entries += HistoryReader.entries(UnsafeRawBufferPointer(rebasing: bytes[lineStart..<end]), kind: file.kind, state: &state)
        lineStart = end + 1
        consumed = min(lineStart, bytes.count)
      }
    }
    let offset = file.compressed ? Int64(consumed) : start + Int64(consumed)
    let saved = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    pass.read += 1
    pass.found += entries.count
    // A file with more than one read's worth left is read on at the next pass.
    let more = !file.compressed && data.count == Self.chunk
    pass.added += try await library.saveUsage(entries, source: UsageSource(id: file.source, offset: offset, size: more ? 0 : size,
                                                                           modified: modified, identity: identity, state: saved))
  }

  /// The most of a file read in one go; the rest is read on the next pass.
  private static let chunk = 64 * 1024 * 1024

  // MARK: OpenCode

  private static let openCodeSource = "opencode"

  /// OpenCode keeps its history in one database, read on from the last
  /// message seen. Its size and change time include the write-ahead log.
  private func readOpenCode(known: UsageSource?, into pass: inout Pass) async throws {
    let path = home.appendingPathComponent(".local/share/opencode/opencode.db").path
    guard FileManager.default.fileExists(atPath: path) else { return }
    var size: Int64 = 0, modified: Int64 = 0
    for file in [path, path + "-wal"] {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else { continue }
      size += (attributes[.size] as? NSNumber)?.int64Value ?? 0
      modified = max(modified, Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000))
    }
    if let known, known.size == size, known.modified == modified { return }
    var cursor = (time: known?.offset ?? 0, id: known?.identity ?? "")
    do {
      try await readOpenCode(path, from: &cursor, size: size, modified: modified, into: &pass)
    } catch {
      // Locked past the wait, corrupt or not OpenCode's: tried again once it changes.
      try await library.saveUsage([], source: UsageSource(id: Self.openCodeSource, offset: cursor.time, size: size,
                                                          modified: modified, identity: cursor.id))
    }
  }

  private func readOpenCode(_ path: String, from cursor: inout (time: Int64, id: String), size: Int64, modified: Int64,
                            into pass: inout Pass) async throws {
    let database = try ReadOnlyDatabase(path: path)
    let limit = 500
    while true {
      let page = try HistoryReader.openCode(database, after: cursor, limit: limit)
      let stuck = page.cursor == cursor
      cursor = page.cursor
      let last = page.rows < limit || stuck
      pass.found += page.entries.count
      pass.added += try await library.saveUsage(page.entries, source: UsageSource(
        id: Self.openCodeSource, offset: cursor.time, size: last ? size : 0, modified: last ? modified : 0, identity: cursor.id))
      if last { break }
    }
    pass.read += 1
  }

  // MARK: Helpers

  private static func source(_ harness: String, _ key: String) -> String {
    harness + ":" + Library.digest(of: Data((harness + "\n" + key).utf8)).prefix(32)
  }

  private static func relative(_ url: URL, to root: URL) -> String {
    let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }

  private static func files(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
      files.append(url)
    }
    return files
  }
}
