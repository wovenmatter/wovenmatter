import Foundation
import CryptoKit
import WovenMatterCompanion

/// The journal's index is atomic, while immutable bodies are written once. Native
/// history stays outside the disposable transcript cache and is never evicted.
enum WorkspaceJournalPersistence {
  private struct Envelope: Codable { var version: Int; var state: WorkspaceJournalState }
  static func load(at file: URL) throws -> WorkspaceJournalState {
    let data = try Data(contentsOf: file)
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      return try JSONDecoder().decode(WorkspaceJournalState.self, from: data)
    }
    guard envelope.version == 2 else { throw WorkspaceJournal.Failure.incompatibleStore }
    var state = envelope.state
    var loaded: [String: Data] = [:]
    try transform(&state) { encodedReference in
      guard let reference = String(data: encodedReference, encoding: .utf8), reference.count == 64,
        reference.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw WorkspaceJournal.Failure.incompatibleStore }
      if let data = loaded[reference] { return data }
      let data = try Data(contentsOf: directory(file).appendingPathComponent(reference))
      guard digest(data) == reference else { throw WorkspaceJournal.Failure.incompatibleStore }
      loaded[reference] = data; return data
    }
    return state
  }
  static func persist(_ source: WorkspaceJournalState, at file: URL) throws {
    var state = source
    var pending: [String: Data] = [:]
    var bytes = 0
    try transform(&state) { data in
      let reference = digest(data)
      if pending[reference] == nil { pending[reference] = data; bytes += data.count }
      guard bytes <= 256 * 1_024 * 1_024 else { throw WorkspaceJournal.Failure.storageFull }
      return Data(reference.utf8)
    }
    let index = try JSONEncoder().encode(Envelope(version: 2, state: state))
    guard index.count <= 256 * 1_024 * 1_024 - bytes else { throw WorkspaceJournal.Failure.storageFull }
    for (reference, data) in pending {
      let blob = directory(file).appendingPathComponent(reference)
      if !FileManager.default.fileExists(atPath: blob.path) { try MobileStorePersistence.writeDurably(data, at: blob) }
    }
    try MobileStorePersistence.writeDurably(index, at: file)
    // Crashes can leave unreferenced bodies; they never remove a live record.
    // History retention/compaction is explicit, not part of cache eviction.
  }
  private static func directory(_ file: URL) -> URL { file.appendingPathExtension("bodies") }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func transform(_ state: inout WorkspaceJournalState, _ body: (Data) throws -> Data) throws {
    func text(_ value: String) throws -> String {
      guard let result = String(data: try body(Data(value.utf8)), encoding: .utf8) else { throw WorkspaceJournal.Failure.incompatibleStore }
      return result
    }
    func transcript(_ value: inout CompanionTranscript) throws {
      for index in value.messages.indices { value.messages[index].content = try text(value.messages[index].content) }
      for index in value.activities.indices {
        if let detail = value.activities[index].detail { value.activities[index].detail = try text(detail) }
      }
    }
    for id in Array(state.entries.keys) {
      if var conversation = state.entries[id]!.conversation {
        conversation.preview = try text(conversation.preview); state.entries[id]!.conversation = conversation
      }
      if var value = state.entries[id]!.transcript { try transcript(&value); state.entries[id]!.transcript = value }
      if let data = state.entries[id]!.nativeRecord?.data { state.entries[id]!.nativeRecord!.data = try body(data) }
    }
    for id in Array(state.conversations.keys) { state.conversations[id]!.preview = try text(state.conversations[id]!.preview) }
    for id in Array(state.transcripts.keys) {
      var value = state.transcripts[id]!; try transcript(&value); state.transcripts[id] = value
    }
    for id in Array(state.commands.keys) {
      if let value = state.commands[id]!.command.text { state.commands[id]!.command.text = try text(value) }
    }
  }
}
