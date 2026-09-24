import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// A small atomic index references immutable content-addressed bodies. A one-line
/// edit never rewrites the rest of the library. Blobs are durable before the index
/// commits; old blobs are collected only after a successful index replacement.
enum MobileStorePersistence {
  private struct Envelope: Codable { var version: Int; var state: MobileStoreState }
  static func load(from file: URL) throws -> MobileStoreState {
    let data = try Data(contentsOf: file)
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      return try JSONDecoder().decode(MobileStoreState.self, from: data)
    }
    guard envelope.version == 2 else { throw MobileStore.Failure.incompatibleStore }
    var state = envelope.state
    try transform(&state) { reference in
      guard reference.count == 64, reference.allSatisfy({ $0.isHexDigit }) else { throw MobileStore.Failure.incompatibleStore }
      let data = try Data(contentsOf: blobDirectory(file).appendingPathComponent(reference))
      guard digest(data) == reference, let content = String(data: data, encoding: .utf8) else { throw MobileStore.Failure.incompatibleStore }
      return content
    }
    return state
  }
  static func persist(_ source: MobileStoreState, at file: URL) throws -> Int {
    let directory = blobDirectory(file)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytesWritten = 0
    var references = Set<String>()
    var state = source
    try transform(&state) { content in
      let data = Data(content.utf8)
      let reference = digest(data)
      references.insert(reference)
      let blob = directory.appendingPathComponent(reference)
      if !FileManager.default.fileExists(atPath: blob.path) {
        try writeDurably(data, at: blob); bytesWritten += data.count
      }
      return reference
    }
    let encoded = try JSONEncoder().encode(Envelope(version: 2, state: state))
    try writeDurably(encoded, at: file); bytesWritten += encoded.count
    // Cleanup is best effort and occurs after the index commits. A crash can leave
    // an orphan, but can never evict a referenced draft, conflict or retry payload.
    if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      for blob in files where !references.contains(blob.lastPathComponent) { try? FileManager.default.removeItem(at: blob) }
    }
    return bytesWritten
  }
  private static func blobDirectory(_ file: URL) -> URL { file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".bodies") }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func transform(_ state: inout MobileStoreState, _ body: (String) throws -> String) throws {
    for id in Array(state.notes.keys) { state.notes[id]!.content = try body(state.notes[id]!.content) }
    for id in Array(state.bases.keys) { state.bases[id]!.content = try body(state.bases[id]!.content) }
    for id in Array(state.conflicts.keys) {
      state.conflicts[id]!.local.content = try body(state.conflicts[id]!.local.content)
      if let value = state.conflicts[id]!.base?.content { state.conflicts[id]!.base!.content = try body(value) }
      if let value = state.conflicts[id]!.remote?.content { state.conflicts[id]!.remote!.content = try body(value) }
    }
    for index in state.outbox.indices { if let value = state.outbox[index].mutation.content { state.outbox[index].mutation.content = try body(value) } }
    for id in Array(state.transcripts.keys) {
      for index in state.transcripts[id]!.messages.indices { state.transcripts[id]!.messages[index].content = try body(state.transcripts[id]!.messages[index].content) }
      for index in state.transcripts[id]!.activities.indices { if let value = state.transcripts[id]!.activities[index].detail { state.transcripts[id]!.activities[index].detail = try body(value) } }
    }
    for index in state.commands.indices { if let value = state.commands[index].command.text { state.commands[index].command.text = try body(value) } }
    for index in state.launches.indices { if let value = state.launches[index].initialSend.text { state.launches[index].initialSend.text = try body(value) } }
    for id in Array(state.chatDrafts.keys) { state.chatDrafts[id]!.text = try body(state.chatDrafts[id]!.text) }
  }
  private static func writeDurably(_ data: Data, at file: URL) throws {
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
    #if canImport(Darwin)
    guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let descriptor = open(directory.path, O_RDONLY)
    if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
    #else
    if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
    else { try FileManager.default.moveItem(at: temporary, to: file) }
    #endif
    var url = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }
}
