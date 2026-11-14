import Foundation
import CryptoKit
import WovenMatterShared
#if canImport(Darwin)
import Darwin
#endif

/// Whether a file may enter iCloud and computer backups. Writing that exists only
/// on this device must survive a restore; caches the library can supply
/// again are excluded. No secret is written here: credentials stay in
/// device-only Keychain items, which backups never restore to another device.
public enum MobileBackup: Sendable { case include, exclude }

/// A small atomic index references immutable content-addressed bodies. A one-line
/// edit never rewrites the rest of the library. Blobs are durable before the index
/// commits; old blobs are collected only after a successful index replacement.
enum MobileStorePersistence {
  private struct Envelope: Codable { var version: Int; var state: MobileStoreState }
  /// Where a body comes from. Cached bodies may be absent after a restore and are fetched again.
  enum BodyRole: Hashable { case local, cachedNote(String), cachedBase(String), cachedTranscript(String) }
  static func load(from file: URL) throws -> MobileStoreState {
    let data = PersistedFieldRenames.upgrade(try Data(contentsOf: file), renaming: PersistedFieldRenames.store)
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      // The earliest stores kept all writing inline in this one excluded file.
      let legacy = try JSONDecoder().decode(MobileStoreState.self, from: data)
      try? applyBackupIfChanged(.include, at: file)
      return legacy
    }
    guard envelope.version == 2 else { throw MobileStore.Failure.incompatibleStore }
    var state = envelope.state
    var missing = Set<BodyRole>(), roles: [String: MobileBackup] = [:]
    try transform(&state) { reference, role in
      guard reference.count == 64, reference.allSatisfy({ $0.isHexDigit }) else { throw MobileStore.Failure.incompatibleStore }
      let blob = blobDirectory(file).appendingPathComponent(reference)
      guard FileManager.default.fileExists(atPath: blob.path) || role == .local else { missing.insert(role); return "" }
      let data = try Data(contentsOf: blob)
      guard digest(data) == reference, let content = String(data: data, encoding: .utf8) else { throw MobileStore.Failure.incompatibleStore }
      roles[reference] = role == .local ? .include : roles[reference] ?? .exclude
      return content
    }
    // A restored backup omits rebuildable caches. Keep their metadata and fetch the bodies again.
    for role in missing {
      switch role {
      case .cachedNote(let id), .cachedBase(let id):
        state.notes[id]?.content = ""; state.notes[id]?.contentIncluded = false
        state.bases[id]?.content = ""; state.bases[id]?.contentIncluded = false
        if state.notes[id] != nil { state.uncachedNoteIDs.insert(id) }
      case .cachedTranscript(let id):
        state.transcripts.removeValue(forKey: id); state.transcriptRecency.removeAll { $0 == id }
      case .local: break
      }
    }
    // Earlier builds excluded everything; include local writing without waiting for an edit.
    // Nothing is excluded in place (see persist).
    for (reference, backup) in roles where backup == .include { try? applyBackupIfChanged(.include, at: blobDirectory(file).appendingPathComponent(reference)) }
    try? applyBackupIfChanged(.include, at: file)
    return state
  }
  static func persist(_ source: MobileStoreState, at file: URL) throws -> Int {
    let directory = blobDirectory(file)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytesWritten = 0
    var references: [String: MobileBackup] = [:]
    var state = source
    try transform(&state) { content, role in
      let data = Data(content.utf8)
      let reference = digest(data)
      // Shared content is included when any local writing references it.
      let backup: MobileBackup = role == .local || references[reference] == .include ? .include : .exclude
      references[reference] = backup
      let blob = directory.appendingPathComponent(reference)
      if !FileManager.default.fileExists(atPath: blob.path) {
        try writeDurably(data, at: blob, backup: backup); bytesWritten += data.count
      }
      return reference
    }
    // Content can move from cache to local writing, such as a note's base once it is
    // edited; inclusion precedes the index commit. A body is never excluded again in
    // place: the system can apply an in-place exclusion late, even to a file later
    // written at the same path. New cache bodies are excluded only as they are written.
    for (reference, backup) in references where backup == .include { try applyBackupIfChanged(.include, at: directory.appendingPathComponent(reference)) }
    let encoded = try JSONEncoder().encode(Envelope(version: 2, state: state))
    try writeDurably(encoded, at: file, backup: .include); bytesWritten += encoded.count
    // Cleanup is best effort and occurs after the index commits. A crash can leave
    // an orphan, but can never evict a referenced draft, conflict or retry payload.
    if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      for blob in files where references[blob.lastPathComponent] == nil { try? FileManager.default.removeItem(at: blob) }
    }
    return bytesWritten
  }
  private static func blobDirectory(_ file: URL) -> URL { file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".bodies") }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).hexString }
  /// Notes are reproducible only after the library has the same revision and content and no local change waits.
  private static func cachedNoteIDs(_ state: MobileStoreState) -> Set<String> {
    guard state.workspaceID != nil else { return [] }
    return Set(state.notes.compactMap { id, note in
      guard !state.isDirty(id), state.pendingNoteDeletions?[id] == nil, let base = state.bases[id],
        base.revision == note.revision, base.content == note.content else { return nil }
      return id
    })
  }
  private static func transform(_ state: inout MobileStoreState, _ body: (String, BodyRole) throws -> String) throws {
    let cachedNotes = cachedNoteIDs(state)
    // Quick Chat history this device owns has no library copy until it is published.
    let ownedTranscripts = (state.ownedConversationIDs ?? []).union(state.executionConversationIDs ?? [])
    for id in Array(state.notes.keys) { state.notes[id]!.content = try body(state.notes[id]!.content, cachedNotes.contains(id) ? .cachedNote(id) : .local) }
    for id in Array(state.bases.keys) { state.bases[id]!.content = try body(state.bases[id]!.content, cachedNotes.contains(id) || state.notes[id] == nil ? .cachedBase(id) : .local) }
    for id in Array(state.pendingNoteDeletions?.keys ?? Dictionary<String, LibraryNote>().keys) {
      var note = state.pendingNoteDeletions![id]!
      note.content = try body(note.content, .local)
      state.pendingNoteDeletions?[id] = note
    }
    for id in Array(state.conflicts.keys) {
      state.conflicts[id]!.local.content = try body(state.conflicts[id]!.local.content, .local)
      if let value = state.conflicts[id]!.base?.content { state.conflicts[id]!.base!.content = try body(value, .local) }
      if let value = state.conflicts[id]!.remote?.content { state.conflicts[id]!.remote!.content = try body(value, .local) }
    }
    for index in state.outbox.indices { if let value = state.outbox[index].mutation.content { state.outbox[index].mutation.content = try body(value, .local) } }
    for id in Array(state.transcripts.keys) {
      let role: BodyRole = ownedTranscripts.contains(id) ? .local : .cachedTranscript(id)
      for index in state.transcripts[id]!.messages.indices { state.transcripts[id]!.messages[index].content = try body(state.transcripts[id]!.messages[index].content, role) }
      for index in state.transcripts[id]!.activities.indices { if let value = state.transcripts[id]!.activities[index].detail { state.transcripts[id]!.activities[index].detail = try body(value, role) } }
    }
    for index in state.commands.indices { if let value = state.commands[index].command.text { state.commands[index].command.text = try body(value, .local) } }
    for index in state.launches.indices { if let value = state.launches[index].initialSend.text { state.launches[index].initialSend.text = try body(value, .local) } }
    for id in Array(state.chatDrafts.keys) { state.chatDrafts[id]!.text = try body(state.chatDrafts[id]!.text, .local) }
  }
  static func applyBackup(_ backup: MobileBackup, at file: URL) throws {
    try setBackupFlag(backup, at: file)
    AppliedBackup.shared.record(backup, at: file.path)
  }
  private static func setBackupFlag(_ backup: MobileBackup, at file: URL) throws {
    if let failure = backupFlagFailure, failure(file, backup) { throw CocoaError(.fileWriteUnknown) }
    var url = file, values = URLResourceValues()
    values.isExcludedFromBackup = backup == .exclude
    try url.setResourceValues(values)
  }
  /// Tests inject a metadata failure for one file and flag; nil in normal use.
  nonisolated(unsafe) static var backupFlagFailure: ((URL, MobileBackup) -> Bool)?
  /// Avoids a metadata write per body on every save; each process verifies each body once.
  static func applyBackupIfChanged(_ backup: MobileBackup, at file: URL) throws {
    guard AppliedBackup.shared.value(at: file.path) != backup else { return }
    try applyBackup(backup, at: file)
  }
  /// Tests simulate a fresh process after another build changed the flags.
  static func forgetAppliedBackups() { AppliedBackup.shared.reset() }
  private final class AppliedBackup: @unchecked Sendable {
    static let shared = AppliedBackup()
    private let lock = NSLock()
    private var values: [String: MobileBackup] = [:]
    func value(at path: String) -> MobileBackup? { lock.withLock { values[path] } }
    func record(_ backup: MobileBackup, at path: String) { lock.withLock { values[path] = backup } }
    func reset() { lock.withLock { values.removeAll() } }
    func forget(_ path: String) { _ = lock.withLock { values.removeValue(forKey: path) } }
  }
  static func writeDurably(_ data: Data, at file: URL, backup: MobileBackup) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary)
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
    #endif
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize(); try handle.close()
    // The flag travels with the file through rename, so a failure to include it
    // in backups happens before the commit and leaves the previous file intact.
    // Only local writing must reach backups; a cache flag failure is harmless.
    let flagged: Bool
    if backup == .include { try setBackupFlag(.include, at: temporary); flagged = true }
    else { flagged = (try? setBackupFlag(.exclude, at: temporary)) != nil }
    #if canImport(Darwin)
    guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let descriptor = open(directory.path, O_RDONLY)
    if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
    #else
    if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
    else { try FileManager.default.moveItem(at: temporary, to: file) }
    #endif
    // Bookkeeping after the commit cannot fail.
    if flagged { AppliedBackup.shared.record(backup, at: file.path) } else { AppliedBackup.shared.forget(file.path) }
  }
}
