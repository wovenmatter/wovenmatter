import Foundation
import WovenMatterShared

/// The one-time conversion of what the release before this one saved on this
/// device. That release wrote a `formatVersion` into the state of each saved
/// index, which is how its files are recognised. A converted index is saved
/// again at once, without one, so each file is converted exactly once. This
/// is the only place that names what that release wrote; everything else
/// reads and writes today's shape.
public enum EarlierPhoneFiles {
  /// Whether a saved index (the store's or the journal's) is that release's.
  /// The parse runs only for a file that mentions the key at all.
  static func isEarlierIndex(_ data: Data) -> Bool {
    guard data.range(of: Data(#""formatVersion""#.utf8)) != nil,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let state = root["state"] as? [String: Any] else { return false }
    return state["formatVersion"] != nil
  }

  /// Quick Chat's saved records (`preferences.json`). That release said what a
  /// record is with a number under `quickChatVersion`: 1 for a Quick Chat, 0
  /// for a chat kept as history. Today a record says `savedHistoryOnly`.
  /// Returns the file in today's shape, or nil when it already is.
  public static func convertedQuickChatPreferences(_ data: Data) -> Data? {
    guard data.range(of: Data(#""quickChatVersion""#.utf8)) != nil,
          var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var conversations = root["conversations"] as? [String: [String: Any]] else { return nil }
    var changed = false
    for (id, var record) in conversations {
      guard let number = record.removeValue(forKey: "quickChatVersion") as? Int else { continue }
      record["savedHistoryOnly"] = number != 1
      conversations[id] = record; changed = true
    }
    guard changed else { return nil }
    root["conversations"] = conversations
    return try? JSONSerialization.data(withJSONObject: root)
  }

  /// The store: every note document held a number under `version`, which a
  /// document does not have. Each stored copy of a note loses it.
  static func convert(_ state: inout MobileStoreState) {
    func converted(_ note: LibraryNote) -> LibraryNote {
      guard let content = EarlierNoteContent.removingVersionMember(note.content) else { return note }
      var note = note
      if note.contentByteCount == note.content.utf8.count { note.contentByteCount = content.utf8.count }
      note.content = content
      return note
    }
    state.notes = state.notes.mapValues(converted)
    state.bases = state.bases.mapValues(converted)
    state.pendingNoteDeletions = state.pendingNoteDeletions?.mapValues(converted)
    state.conflicts = state.conflicts.mapValues { conflict in
      var conflict = conflict
      conflict.local = converted(conflict.local)
      conflict.base = conflict.base.map(converted); conflict.remote = conflict.remote.map(converted)
      return conflict
    }
    for index in state.outbox.indices {
      if let content = state.outbox[index].mutation.content.flatMap(EarlierNoteContent.removingVersionMember) {
        state.outbox[index].mutation.content = content
      }
    }
    if let versions = state.toolNoteVersions {
      state.toolNoteVersions = versions.map { var version = $0; version.note = converted($0.note); return version }
    }
  }

  /// The journal: native records carried numbered format tags, and the copies
  /// of other machines' registry rows carried numbered capability names
  /// (`execution.v1` named nothing a device reads and has no successor).
  /// A record's bytes are covered by its digest and hold no tag; they stay.
  static func convert(_ state: inout WorkspaceJournalState) {
    let formats: [String: NativeRecordFormat] = [
      "wovenmatter.activity.v1": .activity, "wovenmatter.activity.v2": .chainedActivity,
      "pi-durable.entry.v1": .piDurableEntry, "woven-native-update-v1": .nativeUpdate,
      "woven-native-file-manifest/v1": .fileManifest, "woven-native-file-manifest/v2": .fileManifest,
      "woven-native-file-chunk/v1": .fileChunk, "woven-native-record-reference/v1": .recordReference,
      "woven-native-text-fragment/v1": .textFragment,
    ]
    for id in Array(state.entries.keys) {
      if let format = (state.entries[id]?.nativeRecord?.format).flatMap({ formats[$0] }) {
        state.entries[id]?.nativeRecord?.format = format.name
      }
    }
    let capabilities = ["history.library.v1": ExecutionWorkspace.libraryHistoryCapability, "stream.v1": StreamProtocol.capability]
    state.workspaces = state.workspaces.mapValues { workspace in
      var workspace = workspace
      workspace.capabilities = workspace.capabilities.compactMap { $0 == "execution.v1" ? nil : capabilities[$0] ?? $0 }
      return workspace
    }
  }
}
